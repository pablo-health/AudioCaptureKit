using AudioCapture.Capture;
using AudioCapture.Interfaces;
using AudioCapture.Models;
using AudioCapture.Storage;
using NAudio.Wave;
using Xunit;

namespace AudioCapture.Tests;

/// <summary>
/// An encrypted recording is one long chain of [4-byte LE length][sealed box] frames.
/// A single torn frame doesn't cost one chunk — the reader loses its place in the
/// stream, so every byte after the tear is unrecoverable. These tests hold the line
/// on the two ways writes can overlap: concurrent callers into the writer, and the
/// mix timer re-entering itself.
/// </summary>
public class WriteSerializationTests : IDisposable
{
    private readonly string _tempDir;

    public WriteSerializationTests()
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

    /// <summary>
    /// Walks the frame chain to EOF, decrypting each frame. Throws if the framing
    /// desyncs or any frame fails its GCM tag — which is exactly what a torn write
    /// looks like to a reader. <paramref name="headerBytes"/> skips the plaintext WAV
    /// header (44 for the main file, 0 for the raw sidecars).
    /// </summary>
    private static List<byte[]> ReadEncryptedFrames(string path, AesGcmEncryptor encryptor, int headerBytes = 44)
    {
        var bytes = File.ReadAllBytes(path);
        var chunks = new List<byte[]>();
        var offset = headerBytes;

        while (offset < bytes.Length)
        {
            Assert.True(offset + 4 <= bytes.Length,
                $"Truncated length prefix at offset {offset} of {bytes.Length}.");

            var length = BitConverter.ToUInt32(bytes, offset);
            offset += 4;

            Assert.True(length > 0 && offset + length <= bytes.Length,
                $"Frame at offset {offset} claims {length} bytes, but only " +
                $"{bytes.Length - offset} remain — the length prefix desynced.");

            var sealedBox = new byte[length];
            Buffer.BlockCopy(bytes, offset, sealedBox, 0, (int)length);
            offset += (int)length;

            // Throws CryptographicException if the frame straddles a tear.
            chunks.Add(encryptor.Decrypt(sealedBox));
        }

        return chunks;
    }

    [Fact]
    public void ConcurrentWrites_KeepFramingIntact()
    {
        // The writer is reachable from more than one thread in the live pipeline, so
        // the length prefix and its payload have to land as one unit. If they can be
        // split, the frames after the split decode to garbage.
        var path = Path.Combine(_tempDir, "concurrent.enc.wav");
        var encryptor = new AesGcmEncryptor(new byte[32], "test-key");

        using var writer = new EncryptedWavWriter(path, encryptor);
        writer.Open(DefaultConfig);

        const int threads = 8;
        const int writesPerThread = 150;
        var payload = new byte[4096];
        Random.Shared.NextBytes(payload);

        Parallel.For(0, threads, _ =>
        {
            for (int i = 0; i < writesPerThread; i++)
                writer.Write(payload);
        });

        writer.Close();

        var chunks = ReadEncryptedFrames(path, encryptor);
        Assert.Equal(threads * writesPerThread, chunks.Count);
        Assert.All(chunks, c => Assert.Equal(payload, c));
    }

    [Fact]
    public async Task SlowEncryption_DoesNotLetTheMixTimerReEnterItself()
    {
        // The mix timer fires every 100ms. Encryption plus a file write is not
        // guaranteed to finish inside that window — a busy machine, a big buffer, or
        // a slow disk is enough. If the tick can overlap the previous one, two
        // threads interleave into the same stream. The encryptor here is slow on
        // purpose to make that window certain rather than occasional.
        var encryptor = new ConcurrencyTrackingEncryptor(TimeSpan.FromMilliseconds(250));
        var micFixture = WriteFixture("mic.wav", channels: 1);
        var systemFixture = WriteFixture("system.wav", channels: 2);

        var config = DefaultConfig with { Encryptor = encryptor };

        using var session = new WasapiCaptureSession(
            () => FileWaveIn.Mono16(micFixture, loop: true),
            () => FileWaveIn.StereoFloat(systemFixture, loop: true));

        session.Configure(config);
        var capture = session.StartCaptureAsync();

        await Task.Delay(TimeSpan.FromSeconds(2));
        var result = await session.StopCaptureAsync();
        await capture;

        Assert.Equal(1, encryptor.MaxObservedConcurrency);
        Assert.True(encryptor.CallCount > 1, "Expected the mix timer to have written more than once.");

        // Stop has to wait out the in-flight tick before closing the file. A tick that
        // lands after Close fails its write, which is what MixErrors counts.
        Assert.Equal(0, session.Diagnostics.MixErrors);

        var chunks = ReadEncryptedFrames(result.FilePath, new AesGcmEncryptor(ConcurrencyTrackingEncryptor.Key, "test-key"));
        Assert.NotEmpty(chunks);
    }

    [Fact]
    public async Task EncryptedSidecars_RoundTripTheirFraming()
    {
        // The raw-PCM sidecars carry the same [length][sealed box] framing as the main
        // file, written straight from the capture callbacks. This covers the framing
        // round-trip only.
        //
        // It does NOT cover the stop race, and cannot: FileWaveIn.StopRecording waits
        // for its pump, so an injected source can never deliver a callback after stop.
        // Real WasapiCapture.StopRecording only signals its thread and returns, so a
        // live capture can still be mid-write when stop disposes these streams. That
        // gap is unguarded here — macOS covers it with a pcmWriteQueue barrier — and
        // proving it needs real audio hardware.
        var encryptor = new ConcurrencyTrackingEncryptor(TimeSpan.FromMilliseconds(120));
        var micFixture = WriteFixture("mic.wav", channels: 1);
        var systemFixture = WriteFixture("system.wav", channels: 2);

        var config = DefaultConfig with { Encryptor = encryptor, ExportRawPcm = true };

        using var session = new WasapiCaptureSession(
            () => FileWaveIn.Mono16(micFixture, loop: true),
            () => FileWaveIn.StereoFloat(systemFixture, loop: true));

        session.Configure(config);
        var capture = session.StartCaptureAsync();

        await Task.Delay(TimeSpan.FromSeconds(2));
        var result = await session.StopCaptureAsync();
        await capture;

        Assert.NotEmpty(result.RawPcmFilePaths);

        foreach (var sidecar in result.RawPcmFilePaths)
        {
            var chunks = ReadEncryptedFrames(sidecar, new AesGcmEncryptor(ConcurrencyTrackingEncryptor.Key, "test-key"), headerBytes: 0);
            Assert.NotEmpty(chunks);
        }
    }

    private string WriteFixture(string name, int channels)
    {
        var path = Path.Combine(_tempDir, name);
        using var writer = new WaveFileWriter(path, new WaveFormat(48000, 16, channels));
        var frames = 48000 / 2; // 0.5s, looped by the source
        for (int i = 0; i < frames; i++)
        {
            var sample = (float)(Math.Sin(2 * Math.PI * 440 * i / 48000) * 0.5);
            for (int c = 0; c < channels; c++)
                writer.WriteSample(sample);
        }
        return path;
    }

    /// <summary>
    /// A real AES-GCM encryptor that is slow on purpose and records whether it was
    /// ever entered by two threads at once.
    /// </summary>
    private sealed class ConcurrencyTrackingEncryptor : ICaptureEncryptor
    {
        internal static readonly byte[] Key = new byte[32];

        private readonly AesGcmEncryptor _inner = new(Key, "test-key");
        private readonly TimeSpan _delay;
        private int _active;
        private int _maxConcurrency;
        private int _callCount;

        public ConcurrencyTrackingEncryptor(TimeSpan delay) => _delay = delay;

        public int MaxObservedConcurrency => Volatile.Read(ref _maxConcurrency);
        public int CallCount => Volatile.Read(ref _callCount);

        public string Algorithm => _inner.Algorithm;
        public Dictionary<string, string> KeyMetadata => _inner.KeyMetadata;

        public byte[] Encrypt(byte[] data)
        {
            var active = Interlocked.Increment(ref _active);

            int observed;
            while (active > (observed = Volatile.Read(ref _maxConcurrency)))
                Interlocked.CompareExchange(ref _maxConcurrency, active, observed);

            try
            {
                Thread.Sleep(_delay);
                Interlocked.Increment(ref _callCount);
                return _inner.Encrypt(data);
            }
            finally
            {
                Interlocked.Decrement(ref _active);
            }
        }

        public byte[] Decrypt(byte[] data) => _inner.Decrypt(data);
    }
}
