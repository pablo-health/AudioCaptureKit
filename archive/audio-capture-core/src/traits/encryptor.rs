use std::collections::HashMap;

/// Streaming encryption interface for audio chunk encryption.
///
/// Equivalent to Swift's `CaptureEncryptor` protocol.
/// Default implementation uses AES-256-GCM via the `aes-gcm` crate.
///
/// Encrypted chunk format:
/// ```text
/// [12-byte nonce] [ciphertext] [16-byte GCM authentication tag]
/// ```
pub trait CaptureEncryptor: Send + Sync {
    /// Encrypt a chunk of audio data.
    ///
    /// Returns: `nonce (12 bytes) || ciphertext || tag (16 bytes)`
    fn encrypt(&self, data: &[u8]) -> Result<Vec<u8>, String>;

    /// Metadata about the encryption key (e.g., key ID, creation date).
    fn key_metadata(&self) -> HashMap<String, String>;

    /// Algorithm identifier (e.g., "AES-256-GCM").
    fn algorithm(&self) -> &str;

    /// Clone this encryptor into a new boxed trait object.
    ///
    /// Encryptors are stateless (key + algorithm), so cloning is trivial.
    fn clone_box(&self) -> Box<dyn CaptureEncryptor>;
}

// Allow CaptureConfiguration to clone its encryptor via trait object.
impl Clone for Box<dyn CaptureEncryptor> {
    fn clone(&self) -> Self {
        self.clone_box()
    }
}
