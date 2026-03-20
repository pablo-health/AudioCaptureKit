using System.Security.Cryptography;
using AudioCapture.Interfaces;

namespace AudioCapture.Storage;

/// <summary>
/// AES-256-GCM encryptor using .NET built-in cryptography.
/// Output format per chunk: [12-byte nonce] [ciphertext] [16-byte tag]
/// This matches Swift's AES.GCM.SealedBox.combined format exactly.
/// </summary>
public sealed class AesGcmEncryptor : ICaptureEncryptor, IDisposable
{
    private const int NonceSize = 12;
    private const int TagSize = 16;

    private readonly byte[] _key;
    private readonly Dictionary<string, string> _keyMetadata;

    /// <param name="key">32-byte (256-bit) encryption key.</param>
    /// <param name="keyId">Identifier for key tracking/rotation.</param>
    public AesGcmEncryptor(byte[] key, string keyId = "default")
    {
        if (key.Length != 32)
            throw new ArgumentException("Key must be exactly 32 bytes (256 bits).", nameof(key));

        _key = (byte[])key.Clone();
        _keyMetadata = new Dictionary<string, string>
        {
            ["keyId"] = keyId,
            ["algorithm"] = Algorithm,
        };
    }

    public string Algorithm => "AES-256-GCM";

    public Dictionary<string, string> KeyMetadata => new(_keyMetadata);

    public byte[] Encrypt(byte[] data)
    {
        var nonce = new byte[NonceSize];
        RandomNumberGenerator.Fill(nonce);

        var ciphertext = new byte[data.Length];
        var tag = new byte[TagSize];

        using var aes = new AesGcm(_key, TagSize);
        aes.Encrypt(nonce, data, ciphertext, tag);

        // Combined format: nonce || ciphertext || tag (matches Swift AES.GCM.SealedBox.combined)
        var combined = new byte[NonceSize + ciphertext.Length + TagSize];
        Buffer.BlockCopy(nonce, 0, combined, 0, NonceSize);
        Buffer.BlockCopy(ciphertext, 0, combined, NonceSize, ciphertext.Length);
        Buffer.BlockCopy(tag, 0, combined, NonceSize + ciphertext.Length, TagSize);

        return combined;
    }

    /// <summary>
    /// Decrypts data in the combined format: [12-byte nonce] [ciphertext] [16-byte tag].
    /// </summary>
    public byte[] Decrypt(byte[] combined)
    {
        if (combined.Length < NonceSize + TagSize)
            throw new ArgumentException("Data too short to contain nonce and tag.");

        var nonce = new byte[NonceSize];
        var ciphertextLength = combined.Length - NonceSize - TagSize;
        var ciphertext = new byte[ciphertextLength];
        var tag = new byte[TagSize];

        Buffer.BlockCopy(combined, 0, nonce, 0, NonceSize);
        Buffer.BlockCopy(combined, NonceSize, ciphertext, 0, ciphertextLength);
        Buffer.BlockCopy(combined, NonceSize + ciphertextLength, tag, 0, TagSize);

        var plaintext = new byte[ciphertextLength];
        using var aes = new AesGcm(_key, TagSize);
        aes.Decrypt(nonce, ciphertext, tag, plaintext);

        return plaintext;
    }

    public void Dispose()
    {
        CryptographicOperations.ZeroMemory(_key);
    }
}
