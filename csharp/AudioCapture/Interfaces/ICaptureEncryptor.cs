namespace AudioCapture.Interfaces;

/// <summary>
/// Encrypts captured audio data. Mirrors Swift CaptureEncryptor protocol.
/// </summary>
public interface ICaptureEncryptor
{
    /// <summary>
    /// Encrypts the provided data. Returns nonce + ciphertext + tag as a single byte array.
    /// </summary>
    byte[] Encrypt(byte[] data);

    /// <summary>
    /// Metadata about the encryption key (key ID, creation date, etc.).
    /// </summary>
    Dictionary<string, string> KeyMetadata { get; }

    /// <summary>
    /// Algorithm name (e.g. "AES-256-GCM").
    /// </summary>
    string Algorithm { get; }
}
