using AudioCapture.Models;
using AudioCapture.Storage;
using Xunit;

namespace AudioCapture.Tests;

public class EncryptedWavWriterTests : IDisposable
{
    private readonly string _tempDir;

    public EncryptedWavWriterTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"audiocapture_test_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
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

    [Fact]
    public void PlaintextWav_HasCorrectHeader()
    {
        var path = Path.Combine(_tempDir, "test.wav");
        using var writer = new EncryptedWavWriter(path);
        writer.Open(DefaultConfig);

        // Write some PCM data (960 samples = 20ms at 48kHz stereo 16-bit)
        var pcm = new byte[960 * 2 * 2]; // 960 frames * 2 channels * 2 bytes
        writer.Write(pcm);
        writer.Close();

        var file = File.ReadAllBytes(path);

        // RIFF header
        Assert.Equal((byte)'R', file[0]);
        Assert.Equal((byte)'I', file[1]);
        Assert.Equal((byte)'F', file[2]);
        Assert.Equal((byte)'F', file[3]);

        // WAVE format
        Assert.Equal((byte)'W', file[8]);
        Assert.Equal((byte)'A', file[9]);
        Assert.Equal((byte)'V', file[10]);
        Assert.Equal((byte)'E', file[11]);

        // fmt chunk
        Assert.Equal((byte)'f', file[12]);
        Assert.Equal((byte)'m', file[13]);
        Assert.Equal((byte)'t', file[14]);
        Assert.Equal((byte)' ', file[15]);

        // Audio format = 1 (PCM)
        Assert.Equal(1, BitConverter.ToUInt16(file, 20));

        // Channels = 2
        Assert.Equal(2, BitConverter.ToUInt16(file, 22));

        // Sample rate = 48000
        Assert.Equal(48000u, BitConverter.ToUInt32(file, 24));

        // data sub-chunk size
        var dataSize = BitConverter.ToUInt32(file, 40);
        Assert.Equal((uint)pcm.Length, dataSize);
    }

    [Fact]
    public void EncryptedWav_HasChunkedFormat()
    {
        var key = new byte[32];
        Array.Fill(key, (byte)0xAB);
        using var encryptor = new AesGcmEncryptor(key);

        var path = Path.Combine(_tempDir, "test.enc.wav");
        using var writer = new EncryptedWavWriter(path, encryptor);
        writer.Open(DefaultConfig);

        var pcm = new byte[1000];
        new Random(42).NextBytes(pcm);
        writer.Write(pcm);
        var checksum = writer.Close();

        var file = File.ReadAllBytes(path);

        // Header is 44 bytes
        Assert.True(file.Length > 44);

        // After header, first 4 bytes are chunk length
        var chunkLength = BitConverter.ToUInt32(file, 44);

        // Chunk = nonce(12) + ciphertext(1000) + tag(16) = 1028
        Assert.Equal(1028u, chunkLength);

        // Verify the encrypted data can be decrypted
        var encryptedChunk = new byte[chunkLength];
        Array.Copy(file, 48, encryptedChunk, 0, (int)chunkLength);
        var decrypted = encryptor.Decrypt(encryptedChunk);
        Assert.Equal(pcm, decrypted);
    }

    [Fact]
    public void Close_ReturnsSha256Checksum()
    {
        var path = Path.Combine(_tempDir, "test.wav");
        using var writer = new EncryptedWavWriter(path);
        writer.Open(DefaultConfig);
        writer.Write(new byte[100]);
        var checksum = writer.Close();

        // SHA-256 hex is 64 chars
        Assert.Equal(64, checksum.Length);
        Assert.Matches("^[0-9a-f]{64}$", checksum);
    }

    [Fact]
    public void HeaderPatching_UpdatesFileSizeOnClose()
    {
        var path = Path.Combine(_tempDir, "test.wav");
        using var writer = new EncryptedWavWriter(path);
        writer.Open(DefaultConfig);

        // Write two chunks
        writer.Write(new byte[500]);
        writer.Write(new byte[300]);
        writer.Close();

        var file = File.ReadAllBytes(path);

        // RIFF chunk size = fileSize - 8
        var riffSize = BitConverter.ToUInt32(file, 4);
        Assert.Equal((uint)(file.Length - 8), riffSize);

        // data size = total - 44 (header)
        var dataSize = BitConverter.ToUInt32(file, 40);
        Assert.Equal((uint)(file.Length - 44), dataSize);
    }

    [Fact]
    public void GenerateWavHeader_Is44Bytes()
    {
        var header = EncryptedWavWriter.GenerateWavHeader(48000, 16, 2, 0);
        Assert.Equal(44, header.Length);
    }
}
