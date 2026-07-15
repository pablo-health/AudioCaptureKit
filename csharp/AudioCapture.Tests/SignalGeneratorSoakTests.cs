using AudioCapture.Capture;
using AudioCapture.Models;
using Xunit;

namespace AudioCapture.Tests;

/// <summary>
/// Extends the capture soak (see <see cref="CaptureSoakTests"/>) with a deterministic
/// synthetic signal instead of looped file fixtures, so the soak can prove things a plain
/// sine loop can't:
///
/// <list type="bullet">
/// <item><b>Channel separation</b>: mic and system carry distinct, known marker
/// frequencies, so bleed between them is directly detectable.</item>
/// <item><b>Marker timing</b>: markers land on a known schedule, so drift or loss
/// introduced anywhere in the real-time pipeline is directly measurable.</item>
/// <item><b>Leak/duration bounds</b>: resident memory growth and output duration stay
/// within tolerance across the run.</item>
/// </list>
///
/// Same env-tunable duration as <see cref="CaptureSoakTests"/> (<c>SOAK_SECONDS</c>,
/// default 20s) so the weekly workflow's 50-minute run exercises this suite too.
///
/// <para>The C# mirror of Swift <c>SignalGeneratorSoakTests</c>, with one deliberate
/// divergence: the Swift suite folds a pause/resume cycle into this same run, because on
/// that platform pause only quiesces draining and the audio timeline survives it. On
/// Windows pause <i>drops</i> samples at the callback, so folding a pause into the marker
/// run would excise part of the timeline and make marker onsets meaningless. Pause gets
/// its own test below, which asserts the behaviour that actually matters.</para>
/// </summary>
[Trait("Category", "Soak")]
public class SignalGeneratorSoakTests : IDisposable
{
    private const int SampleRate = 48000;
    private const double MarkerPeriod = 10.0;
    private const double MarkerDuration = 1.0;

    // Distinct base/marker pairs per channel, 1 kHz apart so the Goertzel bins don't
    // leak into each other. System markers sit half a period from mic markers so the two
    // channels' bursts never overlap in wall-clock time — a marker on the wrong channel
    // at the wrong time is then unambiguous.
    private static readonly SignalGeneratorWaveIn.MarkerTone MicTone =
        new(BaseFrequency: 1000, MarkerFrequency: 3000, MarkerPeriod: MarkerPeriod,
            MarkerOffset: 0, MarkerDuration: MarkerDuration);

    private static readonly SignalGeneratorWaveIn.MarkerTone SystemTone =
        new(BaseFrequency: 2000, MarkerFrequency: 4000, MarkerPeriod: MarkerPeriod,
            MarkerOffset: MarkerPeriod / 2, MarkerDuration: MarkerDuration);

    private readonly string _tempDir;

    public SignalGeneratorSoakTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"acksoak_markers_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        GC.SuppressFinalize(this);
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    private static double SoakSeconds =>
        double.TryParse(Environment.GetEnvironmentVariable("SOAK_SECONDS"), out var value) && value > 0
            ? value
            : 20.0;

    [Fact]
    public async Task SignalGeneratorProvesChannelSeparationAndMarkerTiming()
    {
        var seconds = SoakSeconds;

        var startRss = MarkerAnalysis.CurrentResidentMemoryBytes();
        var run = await RunAsync(seconds);
        var endRss = MarkerAnalysis.CurrentResidentMemoryBytes();

        Assert.Equal(0, run.Diagnostics.MixErrors);
        AssertBytesWrittenMonotonic(run.BytesWrittenSamples);
        AssertMixCyclesInBallpark(run.Diagnostics.MixCycles, seconds);
        AssertRssGrowthBounded(startRss, endRss);

        // Re-opening and reading the finalized file is itself proof the WAV header/size
        // were written cleanly — a truncated file throws rather than reading garbage.
        var wav = MarkerAnalysis.ReadWavChannels(run.FilePath);
        Assert.Equal(SampleRate, wav.SampleRate);
        Assert.NotEmpty(wav.Left);
        Assert.NotEmpty(wav.Right);

        // Markers are read off the sidecars, not the mix — see MarkerAnalysis.ReadRawPcm
        // for why. The sidecars are also the bytes that get uploaded and transcribed.
        var micSidecar = MarkerAnalysis.ReadRawPcm(run.MicSidecarPath, channels: 1);
        var systemSidecar = MarkerAnalysis.ReadRawPcm(run.SystemSidecarPath, channels: 2);

        AssertChannelMarkers(micSidecar, MicTone, SystemTone.MarkerFrequency, "mic");
        AssertChannelMarkers(systemSidecar, SystemTone, MicTone.MarkerFrequency, "system");
    }

    /// <summary>
    /// The privacy assertion, and the reason pause exists at all: audio captured while
    /// paused must never reach the recording.
    ///
    /// <para>A therapist pauses so that the room can go off the record — a disclosure the
    /// patient doesn't want transcribed, a break, something not clinically relevant. If
    /// paused audio still lands in the file, the button lied to both of them, and it lied
    /// silently. That is a consent problem rather than a convenience bug, so it is worth
    /// proving directly rather than inferring from a state-machine unit test.</para>
    ///
    /// <para>Proven by marker, not by duration: the mic source emits a burst during the
    /// paused window, and its absence from the finalized recording is what "not recorded"
    /// actually means.</para>
    /// </summary>
    [Fact]
    [Trait("Category", "Pause")]
    public async Task AudioCapturedWhilePausedNeverReachesTheRecording()
    {
        // Bursts at source-time 0-1s and 4-5s. The windows below are chosen so every
        // burst sits a full second clear of a capture/pause edge: burst #0 lands well
        // inside the captured head, burst #1 well inside the pause, and the resumed tail
        // ends a second before burst #2 would sound. Without that margin a burst
        // straddling an edge makes a pass and a failure look alike.
        var tone = new SignalGeneratorWaveIn.MarkerTone(
            BaseFrequency: 1000, MarkerFrequency: 3000,
            MarkerPeriod: 4.0, MarkerOffset: 0, MarkerDuration: 1.0);

        using var session = new WasapiCaptureSession(
            () => new SignalGeneratorWaveIn(new NAudio.Wave.WaveFormat(SampleRate, 16, 1), tone),
            systemFactory: null);

        session.Configure(new CaptureConfiguration
        {
            SampleRate = SampleRate,
            BitDepth = 16,
            Channels = 2,
            OutputDirectory = _tempDir,
            EnableMicCapture = true,
            EnableSystemCapture = false,
            MixingStrategy = MixingStrategy.Separated,
        });

        var capture = session.StartCaptureAsync();

        await Task.Delay(TimeSpan.FromSeconds(2.0)); // source 0-2s: burst #0 (0-1s) captured
        session.PauseCapture();
        await Task.Delay(TimeSpan.FromSeconds(3.5)); // source 2-5.5s: burst #1 (4-5s) entirely paused
        session.ResumeCapture();
        await Task.Delay(TimeSpan.FromSeconds(1.5)); // source 5.5-7s: clear of burst #2 (8s)

        var result = await session.StopCaptureAsync();
        await capture;

        var wav = MarkerAnalysis.ReadWavChannels(result.FilePath);
        var wavSeconds = wav.Left.Length / (double)wav.SampleRate;

        // Duration first: it's the unambiguous signal. ~3.5s of audio (2s + 1.5s) means
        // the paused window was excised; ~7s means it was merely delayed and written on
        // resume.
        Assert.True(
            wavSeconds < 5.0,
            $"recording is {wavSeconds:F2}s of a 7s wall clock — the 3.5s pause was not excised, "
                + "so audio captured while paused was written to the recording");

        // And the paused burst specifically is absent. Duration alone could be satisfied
        // by dropping the wrong audio; this pins down that it was the paused audio.
        var markers = MarkerAnalysis.DetectMarkerOnsets(wav.Left, wav.SampleRate, tone.MarkerFrequency);
        Assert.True(
            markers.Count == 1,
            $"expected only the pre-pause marker, found {markers.Count} at "
                + $"[{string.Join(", ", markers.Select(m => $"{m:F2}s"))}] in a {wavSeconds:F2}s recording "
                + "— a burst that sounded while paused reached the recording");
    }

    // --- Assertions ---

    private static void AssertBytesWrittenMonotonic(IReadOnlyList<long> samples)
    {
        for (int i = 1; i < samples.Count; i++)
        {
            Assert.True(
                samples[i] >= samples[i - 1],
                $"bytesWritten decreased: {samples[i - 1]} -> {samples[i]}");
        }
    }

    private static void AssertMixCyclesInBallpark(long mixCycles, double seconds)
    {
        // The mix timer fires every 100ms, so cycles track elapsed seconds x10. Generous
        // bounds absorb startup/final-drain partial cycles. (The Swift graph drains ~1s
        // per cycle, so its equivalent bounds are 10x tighter — same assertion, different
        // constant.)
        var lower = (long)(seconds * 10 * 0.5);
        var upper = ((long)(seconds * 10 * 2)) + 10;
        Assert.True(
            mixCycles >= lower && mixCycles <= upper,
            $"mixCycles {mixCycles} outside expected range {lower}...{upper} for {seconds}s captured");
    }

    private static void AssertRssGrowthBounded(long start, long end)
    {
        var growthMb = end > start ? (end - start) / (1024.0 * 1024.0) : 0;
        // Sized for the 50-minute weekly run, where it needs to be tight enough to catch a
        // real per-cycle leak across ~30 000 mix cycles, but loose enough that one-time
        // setup (JIT, buffers) and a sibling soak's transient allocation in the same
        // process don't flake it.
        Assert.True(growthMb < 150.0, $"resident memory grew by {growthMb:F1}MB across the soak (leak?)");
    }

    /// <summary>
    /// Verifies a channel contains exactly its own marker bursts, on schedule, and none of
    /// the other channel's marker frequency — the proof that mic and system audio didn't
    /// bleed into each other anywhere in the pipeline.
    /// </summary>
    private static void AssertChannelMarkers(
        float[] channel,
        SignalGeneratorWaveIn.MarkerTone ownTone,
        double otherMarkerFrequency,
        string label)
    {
        const int sampleRate = SampleRate;
        var bleed = MarkerAnalysis.DetectMarkerOnsets(channel, sampleRate, otherMarkerFrequency);
        Assert.True(
            bleed.Count == 0,
            $"{label} channel shows {bleed.Count} burst(s) at the OTHER channel's marker "
                + $"frequency {otherMarkerFrequency}Hz — channel separation broken");

        var own = MarkerAnalysis.DetectMarkerOnsets(channel, sampleRate, ownTone.MarkerFrequency);

        // Bound the count against what the sidecar actually holds, not the nominal
        // SOAK_SECONDS: the capture window is bounded by Task.Delay and the stop edge, so
        // a run asked for 20s routinely holds a little more and legitimately catches the
        // burst at 20s. Every burst that finished must be present (that's the loss check);
        // a burst still sounding when capture stopped may or may not have accumulated
        // enough samples to detect, so it's allowed either way.
        var captured = channel.Length / (double)sampleRate;
        var mustBePresent = ExpectedMarkerCount(captured - ownTone.MarkerDuration, ownTone);
        var couldBePresent = ExpectedMarkerCount(captured, ownTone);
        Assert.True(
            own.Count >= mustBePresent && own.Count <= couldBePresent,
            $"{label} channel: expected {mustBePresent}-{couldBePresent} markers at "
                + $"{ownTone.MarkerFrequency}Hz across {captured:F2}s, found {own.Count} "
                + $"at [{string.Join(", ", own.Select(m => $"{m:F2}s"))}]");

        for (int i = 0; i < own.Count; i++)
        {
            var expectedOnset = ownTone.MarkerOffset + (i * ownTone.MarkerPeriod);
            Assert.True(
                Math.Abs(own[i] - expectedOnset) <= 0.02,
                $"{label} marker #{i} detected at {own[i]:F3}s, expected {expectedOnset:F3}s +-0.02s");
        }
    }

    /// <summary>Number of marker bursts that start before <paramref name="totalSeconds"/> elapses.</summary>
    private static int ExpectedMarkerCount(double totalSeconds, SignalGeneratorWaveIn.MarkerTone tone)
    {
        var count = 0;
        for (var burstStart = tone.MarkerOffset; burstStart < totalSeconds; burstStart += tone.MarkerPeriod)
            count++;
        return count;
    }

    // --- Soak harness ---

    private sealed record Run(
        string FilePath,
        string MicSidecarPath,
        string SystemSidecarPath,
        CaptureDiagnostics Diagnostics,
        IReadOnlyList<long> BytesWrittenSamples);

    private async Task<Run> RunAsync(double seconds)
    {
        var config = new CaptureConfiguration
        {
            SampleRate = SampleRate,
            BitDepth = 16,
            Channels = 2,
            OutputDirectory = _tempDir,
            EnableMicCapture = true,
            EnableSystemCapture = true,
            MixingStrategy = MixingStrategy.Separated,
            ExportRawPcm = true,
        };

        using var session = new WasapiCaptureSession(
            () => SignalGeneratorWaveIn.Mono16(MicTone, SampleRate),
            () => SignalGeneratorWaveIn.StereoFloat(SystemTone, SampleRate));

        session.Configure(config);

        var capture = session.StartCaptureAsync();

        // Sample bytesWritten as the run proceeds; a counter that goes backwards points at
        // a torn read or a double-drain, which a single end-of-run reading can't see.
        var samples = new List<long>();
        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < deadline)
        {
            await Task.Delay(TimeSpan.FromMilliseconds(500));
            samples.Add(session.Diagnostics.BytesWritten);
        }

        var result = await session.StopCaptureAsync();
        await capture;

        return new Run(
            result.FilePath,
            result.RawPcmFilePaths[0],
            result.RawPcmFilePaths[1],
            session.Diagnostics,
            samples);
    }
}
