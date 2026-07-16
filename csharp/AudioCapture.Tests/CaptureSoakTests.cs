using AudioCapture.Capture;
using AudioCapture.Models;
using NAudio.Wave;
using Xunit;

namespace AudioCapture.Tests;

/// <summary>
/// Sustained-capture soak: drives the real <see cref="WasapiCaptureSession"/> graph
/// from looped file sources for a long, wall-clock <b>real-time</b> run and asserts
/// the buffers stay clean the whole way — steady throughput, no stall, no unbounded
/// growth.
///
/// <para><b>Why real-time (not accelerated).</b> The failure this guards against is
/// slow: a buffer that drifts, leaks, or stalls only after minutes of continuous
/// producer/consumer traffic. <see cref="FileWaveIn"/>'s <c>speedFactor</c> could
/// push the same samples through in seconds, but that changes the very timing the
/// soak exists to exercise — and would out-run the mix timer, reporting backlog
/// that no real session would see. The point is to prove the graph survives a
/// <i>real</i> 50-minute session.</para>
///
/// <para><b>Duration</b> is env-tunable via <c>SOAK_SECONDS</c> so the PR gate runs a
/// ~20s soak and the weekly workflow runs the full ~50-minute one against the same
/// code path.</para>
///
/// The C# mirror of Swift <c>CaptureSoakTests</c>. The assertions are deliberately
/// not identical: the Swift graph feeds a fixed-capacity ring buffer, so it counts
/// dropped samples on overflow, while this one buffers into growable lists that
/// cannot drop — the same underlying risk (a consumer that can't keep up) surfaces
/// here as unbounded backlog, so <see cref="CaptureDiagnostics.PeakBufferedSamples"/>
/// is what gets bounded.
/// </summary>
[Trait("Category", "Soak")]
public class CaptureSoakTests : IDisposable
{
    private const int SampleRate = 48000;

    private readonly string _tempDir;

    public CaptureSoakTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"acksoak_{Guid.NewGuid():N}");
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

    /// <summary>
    /// One sustained capture, every assertion made against it. Kept as a single test
    /// on purpose: at the weekly duration this run costs 50 minutes of wall clock, so
    /// splitting the assertions would double the bill to prove the same things about
    /// the same graph.
    /// </summary>
    [Fact]
    public async Task SustainedRealTimeCaptureStaysHealthy()
    {
        var seconds = SoakSeconds;
        var (diagnostics, wavFrames) = await RunSoakAsync(seconds);

        // 1. Nothing was lost on the way to disk. A mix cycle that throws drops
        //    whatever it was holding, and nothing downstream would ever know.
        Assert.Equal(0, diagnostics.MixErrors);

        // 2. Both sources delivered throughout and the mixer kept cycling — a stall
        //    leaves these near their starting values.
        Assert.True(diagnostics.MicChunks > 0, "mic source stopped delivering buffers");
        Assert.True(diagnostics.SystemChunks > 0, "system source stopped delivering buffers");
        Assert.True(diagnostics.MixCycles >= 1, "mixer never completed a cycle");

        // 3. Throughput tracked elapsed real time. A stall or silent death mid-soak
        //    shows up as a large shortfall. The floor is generous (>= 50% of a 16-bit
        //    stereo stream) so start/stop edges and pacing jitter don't flake, while a
        //    real stall — which drops toward zero — still trips it.
        var minBytesPerSecond = SampleRate * 2 /* ch */ * 2 /* bytes */ * 0.5;
        var expectedFloor = (long)(minBytesPerSecond * seconds);
        Assert.True(
            diagnostics.BytesWritten >= expectedFloor,
            $"throughput shortfall: wrote {diagnostics.BytesWritten} bytes in {seconds}s, expected >= {expectedFloor}");

        // 4. The backlog stayed bounded. This is the leak assertion: the mix timer
        //    drains every 100 ms, so a healthy run holds well under a second of
        //    audio. A consumer falling behind grows this without limit, and over 50
        //    minutes that is the difference between a stable session and OOM.
        var oneSecondOfSamples = SampleRate * 2;
        Assert.True(
            diagnostics.PeakBufferedSamples < oneSecondOfSamples,
            $"buffer backlog grew to {diagnostics.PeakBufferedSamples} samples "
                + $"(>= {oneSecondOfSamples}, i.e. a second of audio) — the mix timer is not keeping up");

        // 5. Duration was conserved: frames on disk track wall-clock time. This is
        //    what a rate error looks like at the recording level — a file that is
        //    well-formed and full of real audio, but the wrong length, and therefore
        //    played back at the wrong speed.
        //
        //    Tolerance is proportional (+-10%) plus a flat second. The flat part
        //    matters because start/stop edges cost roughly the same regardless of
        //    soak length: ~0.5s of finalize is 10% of a short run but noise in a
        //    50-minute one. Without it a short soak fails on overhead alone; with
        //    it, the proportional band still does the real work at the durations
        //    this test is actually run at.
        var expectedFrames = SampleRate * seconds;
        var edgeSlack = (double)SampleRate;
        Assert.InRange(
            wavFrames,
            (expectedFrames * 0.9) - edgeSlack,
            (expectedFrames * 1.1) + edgeSlack);
    }

    // --- Soak harness ---

    /// <summary>
    /// Wires looped mic + system fixtures through the real graph and captures for
    /// <paramref name="seconds"/> of wall-clock real time.
    /// </summary>
    /// <returns>The session's diagnostics and the finalized WAV's frame count.</returns>
    private async Task<(CaptureDiagnostics Diagnostics, double WavFrames)> RunSoakAsync(double seconds)
    {
        // Short fixtures, looped for the whole soak. Content is irrelevant to buffer
        // reliability; distinct tones per channel keep them realistic.
        var micFixture = WriteSineFixture("mic.wav", frequency: 440, channels: 1);
        var systemFixture = WriteSineFixture("system.wav", frequency: 880, channels: 2);

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
            () => FileWaveIn.Mono16(micFixture, loop: true),
            () => FileWaveIn.StereoFloat(systemFixture, loop: true));

        session.Configure(config);

        var capture = session.StartCaptureAsync();
        await Task.Delay(TimeSpan.FromSeconds(seconds));
        var result = await session.StopCaptureAsync();
        await capture;

        using var reader = new WaveFileReader(result.FilePath);
        return (session.Diagnostics, reader.SampleCount);
    }

    private string WriteSineFixture(string name, double frequency, int channels, double seconds = 3.0)
    {
        var path = Path.Combine(_tempDir, name);
        using var writer = new WaveFileWriter(path, new WaveFormat(SampleRate, 16, channels));
        var frames = (int)(SampleRate * seconds);
        for (int i = 0; i < frames; i++)
        {
            var sample = (float)(Math.Sin(2 * Math.PI * frequency * i / SampleRate) * 0.5);
            for (int c = 0; c < channels; c++)
                writer.WriteSample(sample);
        }
        return path;
    }
}
