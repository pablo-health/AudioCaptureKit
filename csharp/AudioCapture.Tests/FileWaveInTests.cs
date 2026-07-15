using AudioCapture.Capture;
using AudioCapture.Models;
using NAudio.Wave;
using Xunit;

namespace AudioCapture.Tests;

public class FileWaveInTests : IDisposable
{
    private readonly string _tempDir;

    public FileWaveInTests()
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

    /// <summary>Writes a 440 Hz tone fixture — audible signal, so RMS assertions mean something.</summary>
    private string WriteFixture(string name, int sampleRate = 48000, int channels = 1, double seconds = 0.2)
    {
        var path = Path.Combine(_tempDir, name);
        using var writer = new WaveFileWriter(path, new WaveFormat(sampleRate, 16, channels));
        var frames = (int)(sampleRate * seconds);
        for (int i = 0; i < frames; i++)
        {
            var sample = (float)(Math.Sin(2 * Math.PI * 440 * i / sampleRate) * 0.5);
            for (int c = 0; c < channels; c++)
                writer.WriteSample(sample);
        }
        return path;
    }

    /// <summary>Runs a source to end-of-fixture, returning everything it emitted.</summary>
    private static async Task<byte[]> DrainAsync(FileWaveIn source)
    {
        var buffer = new MemoryStream();
        var stopped = new TaskCompletionSource();
        source.DataAvailable += (_, e) => buffer.Write(e.Buffer, 0, e.BytesRecorded);
        source.RecordingStopped += (_, _) => stopped.TrySetResult();

        source.StartRecording();
        await stopped.Task.WaitAsync(TimeSpan.FromSeconds(10));
        return buffer.ToArray();
    }

    [Fact]
    public async Task Mono16_EmitsFixtureAsMonoPcm()
    {
        var fixture = WriteFixture("mic.wav", 48000, 1, 0.2);
        using var source = FileWaveIn.Mono16(fixture, speedFactor: 50);

        var emitted = await DrainAsync(source);

        Assert.Equal(WaveFormatEncoding.Pcm, source.WaveFormat.Encoding);
        Assert.Equal(1, source.WaveFormat.Channels);
        Assert.Equal(48000, source.WaveFormat.SampleRate);
        // 0.2s * 48000 frames * 2 bytes/frame (mono i16)
        Assert.Equal(48000 * 0.2 * 2, emitted.Length);
        Assert.Equal(emitted.Length, source.BytesEmitted);
        Assert.True(source.ChunksEmitted > 1, "fixture should arrive in multiple paced chunks");
    }

    [Fact]
    public async Task StereoFloat_EmitsFloatStereo()
    {
        var fixture = WriteFixture("system.wav", 48000, 2, 0.2);
        using var source = FileWaveIn.StereoFloat(fixture, speedFactor: 50);

        var emitted = await DrainAsync(source);

        Assert.Equal(WaveFormatEncoding.IeeeFloat, source.WaveFormat.Encoding);
        Assert.Equal(2, source.WaveFormat.Channels);
        // 0.2s * 48000 frames * 2 channels * 4 bytes (f32)
        Assert.Equal(48000 * 0.2 * 2 * 4, emitted.Length);
    }

    [Fact]
    public async Task EmittedAudioIsNotSilent()
    {
        var fixture = WriteFixture("tone.wav", 48000, 1, 0.2);
        using var source = FileWaveIn.Mono16(fixture, speedFactor: 50);

        var emitted = await DrainAsync(source);

        var peak = 0;
        for (int i = 0; i + 1 < emitted.Length; i += 2)
            peak = Math.Max(peak, Math.Abs((short)(emitted[i] | (emitted[i + 1] << 8))));
        Assert.True(peak > 1000, $"expected the tone to survive replay, got peak {peak}");
    }

    [Fact]
    public async Task StereoFixture_FoldsToMonoForMicShape()
    {
        var fixture = WriteFixture("stereo-source.wav", 48000, 2, 0.2);
        using var source = FileWaveIn.Mono16(fixture, speedFactor: 50);

        var emitted = await DrainAsync(source);

        // Folded to mono: half the frames' worth of bytes a stereo i16 would give.
        Assert.Equal(48000 * 0.2 * 2, emitted.Length);
    }

    [Fact]
    public async Task MismatchedSampleRate_IsResampledToTarget()
    {
        var fixture = WriteFixture("44k.wav", 44100, 1, 0.2);
        using var source = FileWaveIn.Mono16(fixture, sampleRate: 48000, speedFactor: 50);

        var emitted = await DrainAsync(source);

        // ~0.2s at 48 kHz mono i16. The resampler's tail makes this approximate.
        var frames = emitted.Length / 2.0;
        Assert.InRange(frames, 48000 * 0.19, 48000 * 0.21);
    }

    [Fact]
    public async Task Restart_RewindsToStartOfFixture()
    {
        // A session may probe a source (start → sample → stop) before real capture
        // begins. A non-rewinding source would silently eat the head of the fixture.
        var fixture = WriteFixture("mic.wav", 48000, 1, 0.2);
        using var source = FileWaveIn.Mono16(fixture, speedFactor: 50);

        var first = await DrainAsync(source);
        var second = await DrainAsync(source);

        Assert.NotEmpty(first);
        Assert.Equal(first, second);
    }

    [Fact]
    public async Task Loop_KeepsEmittingPastEndOfFixture()
    {
        var fixture = WriteFixture("mic.wav", 48000, 1, 0.05);
        using var source = FileWaveIn.Mono16(fixture, speedFactor: 50, loop: true);
        var oneShotBytes = 48000 * 0.05 * 2;

        source.StartRecording();
        await Task.Delay(300);
        source.StopRecording();

        Assert.True(
            source.BytesEmitted > oneShotBytes,
            $"looping source should exceed one pass ({oneShotBytes} bytes), emitted {source.BytesEmitted}");
    }

    [Fact]
    public async Task StopRecording_RaisesRecordingStoppedWithoutError()
    {
        var fixture = WriteFixture("mic.wav", 48000, 1, 5.0);
        using var source = FileWaveIn.Mono16(fixture);
        var stopped = new TaskCompletionSource<StoppedEventArgs>();
        source.RecordingStopped += (_, e) => stopped.TrySetResult(e);

        source.StartRecording();
        await Task.Delay(50);
        source.StopRecording();

        var args = await stopped.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Null(args.Exception);
    }

    [Fact]
    public void MissingFixture_ThrowsStorageError()
    {
        using var source = FileWaveIn.Mono16(Path.Combine(_tempDir, "nope.wav"));

        var ex = Assert.Throws<CaptureException>(source.StartRecording);
        Assert.Equal(CaptureErrorKind.StorageError, ex.ErrorKind);
        Assert.False(source.IsAvailable);
    }

    [Fact]
    public async Task WaveFormat_CannotChangeMidRecording()
    {
        var fixture = WriteFixture("mic.wav", 48000, 1, 5.0);
        using var source = FileWaveIn.Mono16(fixture);

        source.StartRecording();
        await Task.Delay(50);

        Assert.Throws<InvalidOperationException>(
            () => source.WaveFormat = new WaveFormat(44100, 16, 1));
        source.StopRecording();
    }
}
