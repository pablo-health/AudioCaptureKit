using AudioCapture.Capture;
using AudioCapture.Models;
using NAudio.Wave;
using Xunit;

namespace AudioCapture.Tests;

/// <summary>
/// Covers the capture-injection seam: with sources injected, the session must run
/// the full pipeline without touching any audio endpoint. These tests are the
/// stand-in for the CI runner, which has no audio devices at all.
/// </summary>
public class WasapiCaptureSessionInjectionTests : IDisposable
{
    private readonly string _tempDir;

    public WasapiCaptureSessionInjectionTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"audiocapture_test_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        GC.SuppressFinalize(this);
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    private CaptureConfiguration DefaultConfig => new()
    {
        SampleRate = 48000,
        BitDepth = 16,
        Channels = 2,
        OutputDirectory = _tempDir,
    };

    private string WriteFixture(string name, int channels = 1, double seconds = 0.3)
    {
        var path = Path.Combine(_tempDir, name);
        using var writer = new WaveFileWriter(path, new WaveFormat(48000, 16, channels));
        var frames = (int)(48000 * seconds);
        for (int i = 0; i < frames; i++)
        {
            var sample = (float)(Math.Sin(2 * Math.PI * 440 * i / 48000) * 0.5);
            for (int c = 0; c < channels; c++)
                writer.WriteSample(sample);
        }
        return path;
    }

    [Fact]
    public async Task SystemEndpointAtADifferentRate_IsReconciledToTheConfiguredRate()
    {
        // A 44.1 kHz render device is ordinary, and its rate is the device's choice,
        // not ours. The sidecar is stamped with the *configured* rate regardless, so
        // an unreconciled endpoint yields audio that plays ~9% fast.
        //
        // Both fixtures play through exactly once (loop: false), so each sidecar holds
        // a fixed sample count set by the fixture length, not by how long the test ran.
        // That is what makes the size ratio stable: looping instead ties each sidecar
        // to the wall clock, and the two stop on independent callback boundaries, so
        // the ratio jitters by a whole chunk either way — enough to cross the 2.0-vs-
        // 1.84 line under load. With a single pass the ratio is deterministic: mic is
        // 48 kHz mono, system reconciles to 48 kHz stereo, so system is ~2x mic; an
        // un-normalized 44.1 kHz system channel would land at ~1.84x instead.
        var micFixture = WriteFixture("mic.wav", channels: 1, seconds: 0.5);
        var systemFixture = WriteFixture("system.wav", channels: 2, seconds: 0.5);

        using var session = new WasapiCaptureSession(
            () => FileWaveIn.Mono16(micFixture, loop: false),
            () => FileWaveIn.StereoFloat(systemFixture, sampleRate: 44100, loop: false));

        session.Configure(DefaultConfig with { ExportRawPcm = true });

        var capture = session.StartCaptureAsync();
        // Comfortably longer than the 0.5s fixtures so both drain fully even under
        // load; the captured sample count is fixed by the fixtures, not this delay.
        await Task.Delay(TimeSpan.FromSeconds(1.5));
        var result = await session.StopCaptureAsync();
        await capture;

        var diagnostics = session.Diagnostics;
        Assert.Equal(44100, diagnostics.SystemSourceSampleRate);
        Assert.True(diagnostics.SystemNormalized, "a 44.1 kHz endpoint must be reconciled");

        var micBytes = new FileInfo(result.RawPcmFilePaths[0]).Length;
        var systemBytes = new FileInfo(result.RawPcmFilePaths[1]).Length;
        var ratio = (double)systemBytes / micBytes;

        // Deterministic at ~2.0 now, so the band only has to separate it from the 1.84
        // an unreconciled endpoint gives.
        Assert.InRange(ratio, 1.95, 2.05);
    }

    [Fact]
    public async Task SystemEndpointAtTheConfiguredRate_IsLeftAlone()
    {
        var micFixture = WriteFixture("mic.wav", channels: 1, seconds: 0.3);
        var systemFixture = WriteFixture("system.wav", channels: 2, seconds: 0.3);

        using var session = new WasapiCaptureSession(
            () => FileWaveIn.Mono16(micFixture, loop: true),
            () => FileWaveIn.StereoFloat(systemFixture, loop: true));

        session.Configure(DefaultConfig);

        var capture = session.StartCaptureAsync();
        await Task.Delay(TimeSpan.FromSeconds(0.5));
        await session.StopCaptureAsync();
        await capture;

        var diagnostics = session.Diagnostics;
        Assert.Equal(48000, diagnostics.SystemSourceSampleRate);
        Assert.Equal(2, diagnostics.SystemSourceChannels);
        Assert.False(diagnostics.SystemNormalized, "a matching endpoint should not be resampled");
    }

    [Fact]
    public void Configure_WithInjectedMic_NeverResolvesADevice()
    {
        var fixture = WriteFixture("mic.wav");
        using var session = new WasapiCaptureSession(
            micFactory: () => FileWaveIn.Mono16(fixture, speedFactor: 50),
            systemFactory: null);

        // A device id no endpoint can have. Were Configure still resolving the mic
        // through MMDeviceEnumerator, this would throw — so reaching Ready proves
        // the enumerator was bypassed rather than merely succeeding on a dev box
        // that happens to have a microphone.
        var config = DefaultConfig with
        {
            MicDeviceId = "{0.0.1.00000000}.{deadbeef-dead-beef-dead-beefdeadbeef}",
            EnableSystemCapture = false,
        };

        session.Configure(config);

        Assert.Equal(CaptureStateKind.Ready, session.State.Kind);
    }

    [Fact]
    public async Task InjectedSources_ProduceRecordingAndSidecars()
    {
        var micFixture = WriteFixture("mic.wav", channels: 1, seconds: 0.3);
        var systemFixture = WriteFixture("system.wav", channels: 2, seconds: 0.3);

        using var session = new WasapiCaptureSession(
            () => FileWaveIn.Mono16(micFixture, speedFactor: 20),
            () => FileWaveIn.StereoFloat(systemFixture, speedFactor: 20));

        session.Configure(DefaultConfig with { ExportRawPcm = true });

        // StartCaptureAsync only completes once stopped, so don't await it here.
        var capture = session.StartCaptureAsync();
        Assert.Equal(CaptureStateKind.Capturing, session.State.Kind);

        await Task.Delay(500); // 0.3s of fixture at 20x drains well inside this
        var result = await session.StopCaptureAsync();
        await capture;

        Assert.True(File.Exists(result.FilePath), "mixed WAV should exist");
        Assert.True(new FileInfo(result.FilePath).Length > 44, "mixed WAV should have audio past the header");

        // Sidecars are what the upload path ships: mic mono, system stereo.
        Assert.Equal(2, result.RawPcmFilePaths.Length);
        foreach (var sidecar in result.RawPcmFilePaths)
            Assert.True(new FileInfo(sidecar).Length > 0, $"{Path.GetFileName(sidecar)} should carry PCM");
    }

    [Fact]
    public async Task Diagnostics_DistinguishSourceFlowFromWriteFlow()
    {
        var micFixture = WriteFixture("mic.wav", channels: 1, seconds: 0.3);
        var systemFixture = WriteFixture("system.wav", channels: 2, seconds: 0.3);

        using var session = new WasapiCaptureSession(
            () => FileWaveIn.Mono16(micFixture, speedFactor: 20),
            () => FileWaveIn.StereoFloat(systemFixture, speedFactor: 20));

        session.Configure(DefaultConfig);
        var capture = session.StartCaptureAsync();
        await Task.Delay(500);
        await session.StopCaptureAsync();
        await capture;

        var diagnostics = session.Diagnostics;
        Assert.True(diagnostics.MicChunks > 0, "mic source should have delivered");
        Assert.True(diagnostics.SystemChunks > 0, "system source should have delivered");
        Assert.True(diagnostics.MicBytes > 0);
        Assert.True(diagnostics.SystemBytes > 0);
        Assert.True(diagnostics.MixCycles > 0, "mix timer should have run");
        Assert.True(diagnostics.BytesWritten > 0, "mixed audio should have reached the writer");
        Assert.Equal(0, diagnostics.MixErrors);
    }

    [Fact]
    public async Task MicOnly_RunsWithSystemCaptureDisabled()
    {
        var micFixture = WriteFixture("mic.wav", channels: 1, seconds: 0.3);

        using var session = new WasapiCaptureSession(
            () => FileWaveIn.Mono16(micFixture, speedFactor: 20),
            systemFactory: null);

        session.Configure(DefaultConfig with { EnableSystemCapture = false });
        var capture = session.StartCaptureAsync();
        await Task.Delay(400);
        var result = await session.StopCaptureAsync();
        await capture;

        Assert.True(session.Diagnostics.MicChunks > 0);
        Assert.Equal(0, session.Diagnostics.SystemChunks);
        Assert.True(File.Exists(result.FilePath));
    }

    [Fact]
    public async Task CompletedSession_CannotBeReconfigured()
    {
        // Pins today's behaviour: a session runs one capture. CaptureState allows
        // Completed → Idle, but nothing on the session performs that reset, so
        // Configure can never be re-entered. Diagnostics therefore accumulate over
        // a single run and need no per-start reset. A future Reset() would change
        // both halves of that, and should land with this test updated.
        var micFixture = WriteFixture("mic.wav", channels: 1, seconds: 0.3);

        using var session = new WasapiCaptureSession(
            () => FileWaveIn.Mono16(micFixture, speedFactor: 20),
            systemFactory: null);

        session.Configure(DefaultConfig with { EnableSystemCapture = false });
        var capture = session.StartCaptureAsync();
        await Task.Delay(300);
        await session.StopCaptureAsync();
        await capture;

        Assert.Equal(CaptureStateKind.Completed, session.State.Kind);
        Assert.Throws<CaptureException>(
            () => session.Configure(DefaultConfig with { EnableSystemCapture = false }));
    }

    [Fact]
    public async Task BlendedStrategy_ReportsCenterMicAndStereoSystem()
    {
        // Blended sums mic into both channels and leaves system stereo, so neither
        // source owns a channel. The metadata must say so — claiming mic=Left/
        // system=Right (the separated shape) would tell the backend it can split
        // speakers by channel when the mix makes that impossible.
        var micFixture = WriteFixture("mic.wav", channels: 1, seconds: 0.3);
        var systemFixture = WriteFixture("system.wav", channels: 2, seconds: 0.3);

        using var session = new WasapiCaptureSession(
            () => FileWaveIn.Mono16(micFixture, speedFactor: 20),
            () => FileWaveIn.StereoFloat(systemFixture, speedFactor: 20));

        session.Configure(DefaultConfig with { MixingStrategy = MixingStrategy.Blended });
        var capture = session.StartCaptureAsync();
        await Task.Delay(500);
        var result = await session.StopCaptureAsync();
        await capture;

        Assert.Equal(ChannelLayout.Blended, result.Metadata.ChannelLayout);
        Assert.Equal(AudioChannel.Center, result.Metadata.Tracks.Single(t => t.Type == AudioTrackType.Mic).Channel);
        Assert.Equal(AudioChannel.Stereo, result.Metadata.Tracks.Single(t => t.Type == AudioTrackType.System).Channel);
    }

    [Fact]
    public async Task SeparatedStrategy_ReportsLeftMicAndRightSystem()
    {
        // Separated genuinely puts mic on Left and the system mono-fold on Right, so
        // the per-channel track claims are true and channel-based diarization works.
        var micFixture = WriteFixture("mic.wav", channels: 1, seconds: 0.3);
        var systemFixture = WriteFixture("system.wav", channels: 2, seconds: 0.3);

        using var session = new WasapiCaptureSession(
            () => FileWaveIn.Mono16(micFixture, speedFactor: 20),
            () => FileWaveIn.StereoFloat(systemFixture, speedFactor: 20));

        session.Configure(DefaultConfig with { MixingStrategy = MixingStrategy.Separated });
        var capture = session.StartCaptureAsync();
        await Task.Delay(500);
        var result = await session.StopCaptureAsync();
        await capture;

        Assert.Equal(ChannelLayout.SeparatedStereo, result.Metadata.ChannelLayout);
        Assert.Equal(AudioChannel.Left, result.Metadata.Tracks.Single(t => t.Type == AudioTrackType.Mic).Channel);
        Assert.Equal(AudioChannel.Right, result.Metadata.Tracks.Single(t => t.Type == AudioTrackType.System).Channel);
    }

    [Fact]
    public async Task MismatchedChunkSizes_MixedLengthTracksTheMicClock()
    {
        // Mic and system arrive in different-sized callbacks, so at each mix tick one
        // side leads the other. Draining both buffers to empty and padding the shorter
        // to max() every cycle fabricated silence on the lagging side and stretched the
        // timeline. Consuming the common minimum and carrying the remainder keeps the
        // mixed length pinned to the true ~0.5s of audio.
        //
        // Single pass (loop: false) so the captured frame count is fixed by the
        // fixtures, not by wall-clock timing.
        var micFixture = WriteFixture("mic.wav", channels: 1, seconds: 0.5);
        var systemFixture = WriteFixture("system.wav", channels: 2, seconds: 0.5);

        using var session = new WasapiCaptureSession(
            () => FileWaveIn.Mono16(micFixture, chunkDuration: TimeSpan.FromMilliseconds(10), loop: false),
            () => FileWaveIn.StereoFloat(systemFixture, chunkDuration: TimeSpan.FromMilliseconds(40), loop: false));

        session.Configure(DefaultConfig with { ExportRawPcm = true });
        var capture = session.StartCaptureAsync();
        await Task.Delay(TimeSpan.FromSeconds(1.5)); // both fixtures drain well inside this
        var result = await session.StopCaptureAsync();
        await capture;

        // Plaintext sidecar (i16 mono) and mixed WAV (i16 stereo, 44-byte header).
        var micSidecarFrames = new FileInfo(result.RawPcmFilePaths[0]).Length / 2;
        var mixedFrames = (new FileInfo(result.FilePath).Length - 44) / 4;

        // Every mic frame maps to one mixed frame; no padding adds frames beyond it.
        Assert.InRange(mixedFrames, micSidecarFrames - 480, micSidecarFrames + 480);
        // And that length is the real 0.5s (24000 frames @ 48 kHz), not an inflated one.
        Assert.InRange(mixedFrames, 24000 - 480, 24000 + 480);
    }
}
