using AudioCapture.Storage;
using SampleApp.Services;
using Xunit;

namespace SampleApp.Tests;

public class DemoEncryptorTests
{
    [Fact]
    public void Encrypt_Decrypt_RoundTrip()
    {
        var encryptor = new DemoEncryptor();
        var plaintext = new byte[] { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

        var encrypted = encryptor.Encrypt(plaintext);

        // Decrypt using AesGcmEncryptor with the same demo key
        var key = new byte[]
        {
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
            0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
            0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
        };
        var decryptor = new AesGcmEncryptor(key);
        var decrypted = decryptor.Decrypt(encrypted);

        Assert.Equal(plaintext, decrypted);
    }

    [Fact]
    public void Encrypt_ProducesDifferentNonces()
    {
        var encryptor = new DemoEncryptor();
        var data = new byte[] { 1, 2, 3 };

        var enc1 = encryptor.Encrypt(data);
        var enc2 = encryptor.Encrypt(data);

        // First 12 bytes are the nonce — should differ
        Assert.NotEqual(enc1[..12], enc2[..12]);
    }

    [Fact]
    public void KeyMetadata_HasExpectedValues()
    {
        var encryptor = new DemoEncryptor();

        Assert.Equal("AES-256-GCM", encryptor.Algorithm);
        Assert.Equal("demo-key-v1", encryptor.KeyMetadata["keyId"]);
        Assert.Contains("DEMO KEY", encryptor.KeyMetadata["warning"]);
    }

    [Fact]
    public void Encrypt_OutputFormat_NonceAndCiphertextAndTag()
    {
        var encryptor = new DemoEncryptor();
        var data = new byte[100];

        var encrypted = encryptor.Encrypt(data);

        // Expected: 12 (nonce) + 100 (ciphertext) + 16 (tag) = 128
        Assert.Equal(128, encrypted.Length);
    }

    [Fact]
    public void DemoKey_MatchesMacOSAndRust()
    {
        // The demo key is sequential bytes 0x01..0x20 — same across all platforms
        var encryptor = new DemoEncryptor();
        var data = new byte[] { 42 };
        var encrypted = encryptor.Encrypt(data);

        // Verify with known key
        var key = new byte[32];
        for (int i = 0; i < 32; i++) key[i] = (byte)(i + 1);
        var dec = new AesGcmEncryptor(key);
        var result = dec.Decrypt(encrypted);

        Assert.Equal(new byte[] { 42 }, result);
    }
}
