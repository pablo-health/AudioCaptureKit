using System.Collections.Concurrent;
using System.Security.Cryptography;
using AudioCapture.Capture;
using AudioCapture.Interfaces;
using AudioCapture.Models;
using AudioCapture.Storage;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Xunit;

using CaptureState = AudioCapture.Models.CaptureState;

namespace AudioCapture.Tests;

/// <summary>
/// The system channel across the things a real output device does mid-session: goes
/// silent (loopback delivers nothing), changes under us (a headset is plugged in),
/// dies with an error, or runs at a rate other than the configured one. All with
/// injected sources, so none of it needs an audio endpoint.
///
/// These measure sidecar lengths against the wall clock, so they run in the
/// non-parallel real-time collection rather than competing with the CPU-bound suite.
/// </summary>
[Collection("RealtimeSoak")]
public class DeviceFollowingTests : IDisposable
{
    private const int Rate = 48000;

    // 50 ms at 48 kHz: the acceptance bound between the two sidecars.
    private const long FiftyMsFrames = Rate / 20;

    private readonly string _tempDir;

    public DeviceFollowingTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"ackdev_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        GC.SuppressFinalize(this);
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    private CaptureConfiguration Config => new()
    {
        SampleRate = Rate,
        BitDepth = 16,
        Channels = 2,
        OutputDirectory = _tempDir,
        ExportRawPcm = true,
        MixingStrategy = MixingStrategy.Separated,
    };

    [Fact]
    public async Task SilentSystemSource_SidecarStillMatchesTheMicDuration()
    {
        // Loopback delivers nothing while nothing renders. Ten silent seconds in the
        // middle of a session must not shorten the system sidecar: it stays on the
        // mic's timeline, padded with silence.
        var system = new ScriptedWaveIn(Rate, isSilent: t => t >= 2.0 && t < 12.0);

        using var session = new WasapiCaptureSession(
            () => new ScriptedWaveIn(Rate, frequency: 440, stereoFloat: false),
            () => system);
        session.Configure(Config);

        var capture = session.StartCaptureAsync();
        await Task.Delay(TimeSpan.FromSeconds(14));
        var result = await session.StopCaptureAsync();
        await capture;

        var micFrames = new FileInfo(result.RawPcmFilePaths[0]).Length / 2;
        var systemFrames = new FileInfo(result.RawPcmFilePaths[1]).Length / 4;

        Assert.InRange(systemFrames, micFrames - FiftyMsFrames, micFrames + FiftyMsFrames);

        // And it got there by padding the gap, not by the source covering it.
        var diagnostics = session.Diagnostics;
        Assert.True(
            diagnostics.SystemPaddedFrames >= (long)(9.5 * Rate),
            $"expected ~10 s of padding, got {diagnostics.SystemPaddedFrames} frames");

        // The padding sits where the gap was: the middle of the sidecar is silent,
        // both ends carry the tone.
        var pcm = File.ReadAllBytes(result.RawPcmFilePaths[1]);
        Assert.True(PeakAt(pcm, seconds: 1.0) > 0.3, "tone expected before the gap");
        Assert.True(PeakAt(pcm, seconds: 7.0) < 0.01, "silence expected inside the gap");
        Assert.True(PeakAt(pcm, seconds: 13.0) > 0.3, "tone expected after the gap");
    }

    [Fact]
    public async Task DefaultDeviceChange_SwapsTheSystemSourceIntoOneContinuousSidecar()
    {
        // A headset plugged in mid-session: the Console default render device changes
        // and loopback re-opens on it — here at a different rate, so the normalizer has
        // to be rebuilt too. Same writers throughout: one decryptable sidecar.
        using var encryptor = new AesGcmEncryptor(RandomNumberGenerator.GetBytes(32));
        var sources = new List<ScriptedWaveIn>
        {
            new(Rate),
            new(44100),
        };
        var factoryCalls = 0;
        var events = new RecordingDelegate();

        using var session = new WasapiCaptureSession(
            () => new ScriptedWaveIn(Rate, frequency: 440, stereoFloat: false),
            () => sources[Interlocked.Increment(ref factoryCalls) - 1]);
        session.Delegate = events;
        session.Configure(Config with { Encryptor = encryptor, FollowDefaultOutputDevice = true });

        var capture = session.StartCaptureAsync();
        await Task.Delay(TimeSpan.FromSeconds(1));

        // Other roles and flows are not followed.
        await session.HandleDefaultDeviceChanged(DataFlow.Render, Role.Multimedia, "{other}");
        await session.HandleDefaultDeviceChanged(DataFlow.Capture, Role.Console, "{other}");
        Assert.Equal(1, factoryCalls);

        await session.HandleDefaultDeviceChanged(DataFlow.Render, Role.Console, "{headset}");
        Assert.Equal(2, factoryCalls);
        Assert.False(sources[0].IsRecording, "the old source should be stopped");

        await Task.Delay(TimeSpan.FromSeconds(1.5));
        var result = await session.StopCaptureAsync();
        await capture;

        var mic = SidecarStreamWriter.ReadEncrypted(result.RawPcmFilePaths[0], encryptor.Decrypt);
        var system = SidecarStreamWriter.ReadEncrypted(result.RawPcmFilePaths[1], encryptor.Decrypt);
        var micFrames = mic.Length / 2;
        var systemFrames = system.Length / 4;
        Assert.InRange(systemFrames, micFrames - FiftyMsFrames, micFrames + FiftyMsFrames);

        // The tone continues on the new device, resampled to the configured rate.
        Assert.True(PeakAt(system, seconds: 2.0) > 0.3, "tone expected from the new device");

        var diagnostics = session.Diagnostics;
        Assert.Equal(1, diagnostics.SystemSourceSwitches);
        Assert.Equal(44100, diagnostics.SystemSourceSampleRate);
        Assert.Contains(events.DeviceChanges, c => c.Kind == CaptureDeviceChangeKind.SystemOutputSwitched);
    }

    [Fact]
    public async Task DefaultDeviceChange_IsIgnoredWhenFollowingIsOff()
    {
        var factoryCalls = 0;
        using var session = new WasapiCaptureSession(
            () => new ScriptedWaveIn(Rate, stereoFloat: false),
            () =>
            {
                Interlocked.Increment(ref factoryCalls);
                return new ScriptedWaveIn(Rate);
            });
        session.Configure(Config);

        var capture = session.StartCaptureAsync();
        await session.HandleDefaultDeviceChanged(DataFlow.Render, Role.Console, "{headset}");
        await session.StopCaptureAsync();
        await capture;

        Assert.Equal(1, factoryCalls);
    }

    [Fact]
    public async Task SystemRecordingStoppedWithException_ReachesOnError()
    {
        var events = new RecordingDelegate();
        using var session = new WasapiCaptureSession(
            () => new ScriptedWaveIn(Rate, stereoFloat: false),
            () => new ScriptedWaveIn(Rate, failAfter: TimeSpan.FromMilliseconds(300)));
        session.Delegate = events;
        session.Configure(Config);

        var capture = session.StartCaptureAsync();
        var reported = await events.WaitForErrorAsync(TimeSpan.FromSeconds(5));
        await session.StopCaptureAsync();
        await capture;

        Assert.NotNull(reported);
        Assert.Equal(CaptureErrorKind.DeviceNotAvailable, reported.ErrorKind);
        Assert.Contains("System audio stopped", reported.Message);
        Assert.Equal(1, session.Diagnostics.SystemSourceErrors);
    }

    [Fact]
    public async Task SystemError_WithFollowing_ReopensTheSource()
    {
        var factoryCalls = 0;
        var events = new RecordingDelegate();
        using var session = new WasapiCaptureSession(
            () => new ScriptedWaveIn(Rate, stereoFloat: false),
            () => Interlocked.Increment(ref factoryCalls) == 1
                ? new ScriptedWaveIn(Rate, failAfter: TimeSpan.FromMilliseconds(200))
                : new ScriptedWaveIn(Rate));
        session.Delegate = events;
        session.Configure(Config with { FollowDefaultOutputDevice = true });

        var capture = session.StartCaptureAsync();
        await Task.Delay(TimeSpan.FromSeconds(1.5)); // 200 ms to fail, 500 ms back-off
        await session.StopCaptureAsync();
        await capture;

        Assert.Equal(2, factoryCalls);
        Assert.Equal(1, session.Diagnostics.SystemSourceSwitches);
        Assert.NotNull(await events.WaitForErrorAsync(TimeSpan.Zero));
    }

    [Fact]
    public async Task Diagnostics_ReportTheMicFormatAndMeasuredRate()
    {
        using var session = new WasapiCaptureSession(
            () => new ScriptedWaveIn(Rate, stereoFloat: false),
            () => new ScriptedWaveIn(Rate));
        session.Configure(Config);

        var capture = session.StartCaptureAsync();
        await Task.Delay(TimeSpan.FromSeconds(2));
        var live = session.Diagnostics;
        await session.StopCaptureAsync();
        await capture;

        Assert.Equal(Rate, live.MicSampleRate);
        Assert.Equal(1, live.MicChannels);
        Assert.Equal(16, live.MicBitsPerSample);
        Assert.Equal("Pcm", live.MicEncoding);
        Assert.Equal(Rate, live.SidecarSampleRate);
        Assert.InRange(live.MicMeasuredSampleRate, Rate * 0.9, Rate * 1.1);
    }

    [Fact]
    public async Task AppendMode_TwoRunsDecryptAsOneStream()
    {
        // A stalled recording restarted by a new session appends to the same sidecars.
        // Each encrypted chunk is self-delimiting, so the runs concatenate.
        using var encryptor = new AesGcmEncryptor(RandomNumberGenerator.GetBytes(32));
        var micPath = Path.Combine(_tempDir, "session_mic.enc.pcm");
        var systemPath = Path.Combine(_tempDir, "session_system.enc.pcm");
        var config = Config with
        {
            Encryptor = encryptor,
            MicSidecarPath = micPath,
            SystemSidecarPath = systemPath,
            AppendToSidecars = true,
        };

        var first = await RunOnceAsync(config, TimeSpan.FromSeconds(0.8));
        var afterFirst = File.ReadAllBytes(systemPath);
        var firstFrames = SidecarStreamWriter.ReadEncrypted(systemPath, encryptor.Decrypt).Length / 4;
        var firstMicFrames = SidecarStreamWriter.ReadEncrypted(micPath, encryptor.Decrypt).Length / 2;

        var second = await RunOnceAsync(config, TimeSpan.FromSeconds(0.8));
        Assert.Equal([micPath, systemPath], first.RawPcmFilePaths);
        Assert.Equal([micPath, systemPath], second.RawPcmFilePaths);

        // The first run is an untouched prefix of the combined file...
        var combined = File.ReadAllBytes(systemPath);
        Assert.True(combined.Length > afterFirst.Length);
        Assert.Equal(afterFirst, combined[..afterFirst.Length]);

        // ...and the whole thing decrypts as one stream, roughly twice as long.
        var systemFrames = SidecarStreamWriter.ReadEncrypted(systemPath, encryptor.Decrypt).Length / 4;
        var micFrames = SidecarStreamWriter.ReadEncrypted(micPath, encryptor.Decrypt).Length / 2;
        Assert.InRange(systemFrames, (long)(firstFrames * 1.7), (long)(firstFrames * 2.3));
        Assert.InRange(micFrames, (long)(firstMicFrames * 1.7), (long)(firstMicFrames * 2.3));
    }

    [Fact]
    public async Task SystemSourceAt44100_SidecarPlaysAtTheRightSpeedUnderThe48kContract()
    {
        // A 44.1 kHz output device. The sidecar is consumed as 48 kHz, so a 1 kHz tone
        // must still read as 1 kHz there, and two seconds of it must still be two
        // seconds. Un-normalized it would read as ~1088 Hz over ~1.84 s.
        var system = new ScriptedWaveIn(44100, frequency: 1000, isSilent: t => t >= 2.0);

        using var session = new WasapiCaptureSession(
            () => new ScriptedWaveIn(Rate, frequency: 440, stereoFloat: false),
            () => system);
        session.Configure(Config);

        var capture = session.StartCaptureAsync();
        await Task.Delay(TimeSpan.FromSeconds(2.5));
        var result = await session.StopCaptureAsync();
        await capture;

        var pcm = File.ReadAllBytes(result.RawPcmFilePaths[1]);
        var left = LeftChannel(pcm);

        var first = Array.FindIndex(left, s => Math.Abs(s) > 0.05f);
        var last = Array.FindLastIndex(left, s => Math.Abs(s) > 0.05f);
        Assert.True(first >= 0, "the tone should be in the sidecar");

        var toneSeconds = (last - first) / (double)Rate;
        Assert.InRange(toneSeconds, 1.96, 2.04);

        // Rising zero crossings over the tone, read at the contract rate.
        var crossings = 0;
        for (int i = first + 1; i <= last; i++)
            if (left[i - 1] < 0 && left[i] >= 0) crossings++;
        var frequency = crossings / toneSeconds;
        Assert.InRange(frequency, 990, 1010);
    }

    // --- Helpers ---

    private async Task<RecordingResult> RunOnceAsync(CaptureConfiguration config, TimeSpan length)
    {
        using var session = new WasapiCaptureSession(
            () => new ScriptedWaveIn(Rate, frequency: 440, stereoFloat: false),
            () => new ScriptedWaveIn(Rate));
        session.Configure(config);
        var capture = session.StartCaptureAsync();
        await Task.Delay(length);
        var result = await session.StopCaptureAsync();
        await capture;
        return result;
    }

    /// <summary>Left channel of i16 stereo PCM as floats.</summary>
    private static float[] LeftChannel(byte[] pcm)
    {
        var frames = pcm.Length / 4;
        var left = new float[frames];
        for (int i = 0; i < frames; i++)
            left[i] = BitConverter.ToInt16(pcm, i * 4) / (float)short.MaxValue;
        return left;
    }

    /// <summary>Peak of the left channel over the 100 ms starting at <paramref name="seconds"/>.</summary>
    private static float PeakAt(byte[] pcm, double seconds)
    {
        var left = LeftChannel(pcm);
        var start = (int)(seconds * Rate);
        var end = Math.Min(left.Length, start + (Rate / 10));
        float peak = 0;
        for (int i = start; i < end; i++)
            peak = Math.Max(peak, Math.Abs(left[i]));
        return peak;
    }

    private sealed class RecordingDelegate : ICaptureDelegate
    {
        private readonly TaskCompletionSource<CaptureException> _firstError =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public ConcurrentQueue<CaptureDeviceChange> DeviceChanges { get; } = new();

        public void OnStateChanged(CaptureState state)
        {
        }

        public void OnLevelsUpdated(AudioLevels levels)
        {
        }

        public void OnError(CaptureException error) => _firstError.TrySetResult(error);

        public void OnCaptureFinished(RecordingResult result)
        {
        }

        public void OnDeviceChanged(CaptureDeviceChange change) => DeviceChanges.Enqueue(change);

        public async Task<CaptureException?> WaitForErrorAsync(TimeSpan timeout)
        {
            if (_firstError.Task.IsCompleted) return _firstError.Task.Result;
            var done = await Task.WhenAny(_firstError.Task, Task.Delay(timeout));
            return ReferenceEquals(done, _firstError.Task) ? _firstError.Task.Result : null;
        }
    }
}
