using AudioCapture.Storage;
using Xunit;

namespace AudioCapture.Tests;

public class AesGcmEncryptorTests
{
    private static readonly byte[] TestKey =
    [
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
    ];

    [Fact]
    public void RoundTrip_EncryptDecrypt()
    {
        using var encryptor = new AesGcmEncryptor(TestKey, "test-key");
        var plaintext = new byte[] { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

        var encrypted = encryptor.Encrypt(plaintext);
        var decrypted = encryptor.Decrypt(encrypted);

        Assert.Equal(plaintext, decrypted);
    }

    [Fact]
    public void Encrypt_ProducesCorrectOverhead()
    {
        // AES-GCM combined = 12 (nonce) + plaintext + 16 (tag) = 28 bytes overhead
        using var encryptor = new AesGcmEncryptor(TestKey);
        var plaintext = new byte[100];

        var encrypted = encryptor.Encrypt(plaintext);

        Assert.Equal(100 + 28, encrypted.Length);
    }

    [Fact]
    public void Encrypt_NoncesAreUnique()
    {
        using var encryptor = new AesGcmEncryptor(TestKey);
        var plaintext = new byte[16];

        var enc1 = encryptor.Encrypt(plaintext);
        var enc2 = encryptor.Encrypt(plaintext);

        // First 12 bytes are the nonce — they should differ
        var nonce1 = enc1[..12];
        var nonce2 = enc2[..12];
        Assert.NotEqual(nonce1, nonce2);
    }

    [Fact]
    public void Decrypt_WrongKey_Throws()
    {
        using var encryptor = new AesGcmEncryptor(TestKey);
        var encrypted = encryptor.Encrypt([1, 2, 3, 4]);

        var wrongKey = new byte[32];
        Array.Fill(wrongKey, (byte)0xFF);
        using var wrongEncryptor = new AesGcmEncryptor(wrongKey);

        Assert.ThrowsAny<Exception>(() => wrongEncryptor.Decrypt(encrypted));
    }

    [Fact]
    public void Decrypt_TamperedTag_Throws()
    {
        using var encryptor = new AesGcmEncryptor(TestKey);
        var encrypted = encryptor.Encrypt([1, 2, 3, 4]);

        // Flip a bit in the tag (last 16 bytes)
        encrypted[^1] ^= 0xFF;

        Assert.ThrowsAny<Exception>(() => encryptor.Decrypt(encrypted));
    }

    [Fact]
    public void Algorithm_ReturnsAes256Gcm()
    {
        using var encryptor = new AesGcmEncryptor(TestKey);
        Assert.Equal("AES-256-GCM", encryptor.Algorithm);
    }

    [Fact]
    public void KeyMetadata_ContainsKeyId()
    {
        using var encryptor = new AesGcmEncryptor(TestKey, "my-key-v1");
        var meta = encryptor.KeyMetadata;

        Assert.Equal("my-key-v1", meta["keyId"]);
        Assert.Equal("AES-256-GCM", meta["algorithm"]);
    }

    [Fact]
    public void Constructor_RejectsWrongKeySize()
    {
        Assert.Throws<ArgumentException>(() => new AesGcmEncryptor(new byte[16]));
        Assert.Throws<ArgumentException>(() => new AesGcmEncryptor(new byte[64]));
    }
}
