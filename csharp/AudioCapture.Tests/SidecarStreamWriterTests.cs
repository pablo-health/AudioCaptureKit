using System.Security.Cryptography;
using AudioCapture.Storage;
using Xunit;

namespace AudioCapture.Tests;

public class SidecarStreamWriterTests : IDisposable
{
    private readonly string _tempDir;

    public SidecarStreamWriterTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"acksidecar_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        GC.SuppressFinalize(this);
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    [Fact]
    public void EncryptedAppend_ConcatenatesIntoOneDecryptableStream()
    {
        using var encryptor = new AesGcmEncryptor(RandomNumberGenerator.GetBytes(32));
        var path = Path.Combine(_tempDir, "s.enc.pcm");

        using (var first = new SidecarStreamWriter(path, encryptor))
        {
            first.Write([1, 2, 3]);
            first.Write([4, 5]);
        }
        using (var second = new SidecarStreamWriter(path, encryptor, append: true))
        {
            Assert.Equal(0, second.RepairedTailBytes);
            second.Write([6, 7, 8, 9]);
        }

        Assert.Equal([1, 2, 3, 4, 5, 6, 7, 8, 9], SidecarStreamWriter.ReadEncrypted(path, encryptor.Decrypt));
    }

    [Fact]
    public void EncryptedAppend_RepairsATornTailFirst()
    {
        // A run killed mid-write leaves a partial final frame. Appending after it as-is
        // would desync every frame that follows; the writer cuts back to the last whole
        // frame instead, losing only the torn chunk.
        using var encryptor = new AesGcmEncryptor(RandomNumberGenerator.GetBytes(32));
        var path = Path.Combine(_tempDir, "s.enc.pcm");

        using (var first = new SidecarStreamWriter(path, encryptor))
        {
            first.Write([1, 2, 3]);
            first.Write([4, 5, 6]);
        }
        using (var stream = new FileStream(path, FileMode.Open))
            stream.SetLength(stream.Length - 5);

        using (var second = new SidecarStreamWriter(path, encryptor, append: true))
        {
            Assert.True(second.RepairedTailBytes > 0);
            second.Write([7, 8]);
        }

        Assert.Equal([1, 2, 3, 7, 8], SidecarStreamWriter.ReadEncrypted(path, encryptor.Decrypt));
    }

    [Fact]
    public void PlaintextAppend_TrimsToTheCallersAlignment()
    {
        var path = Path.Combine(_tempDir, "s.pcm");
        File.WriteAllBytes(path, [1, 2, 3, 4, 5]); // one torn byte past a 4-byte unit

        using (var writer = new SidecarStreamWriter(path, append: true, plaintextAlignment: 4))
        {
            Assert.Equal(1, writer.RepairedTailBytes);
            writer.Write([9, 9, 9, 9]);
        }

        Assert.Equal([1, 2, 3, 4, 9, 9, 9, 9], File.ReadAllBytes(path));
    }

    [Fact]
    public void WithoutAppend_TheFileStartsOver()
    {
        var path = Path.Combine(_tempDir, "s.pcm");
        File.WriteAllBytes(path, [1, 2, 3, 4]);

        using (var writer = new SidecarStreamWriter(path))
            writer.Write([7, 7]);

        Assert.Equal([7, 7], File.ReadAllBytes(path));
    }

    [Fact]
    public void WriteAfterClose_IsDropped()
    {
        var path = Path.Combine(_tempDir, "s.pcm");
        var writer = new SidecarStreamWriter(path);
        writer.Write([1]);
        writer.Close();
        writer.Write([2]);

        Assert.Equal([1], File.ReadAllBytes(path));
    }
}
