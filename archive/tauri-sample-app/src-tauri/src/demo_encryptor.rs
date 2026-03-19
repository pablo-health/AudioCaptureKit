use std::collections::HashMap;

use aes_gcm::aead::{Aead, KeyInit, OsRng};
use aes_gcm::{Aes256Gcm, AeadCore, Key};
use audio_capture_core::CaptureEncryptor;

/// Demo AES-256-GCM encryptor with a hardcoded key.
///
/// **NOT FOR PRODUCTION** — matches the macOS `DemoEncryptor` for interop testing.
/// Encrypted chunk format: `nonce (12B) || ciphertext || tag (16B)`.
pub struct DemoEncryptor {
    cipher: Aes256Gcm,
}

/// Hardcoded 32-byte demo key (identical to macOS DemoEncryptor).
const DEMO_KEY_BYTES: [u8; 32] = [
    0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
    0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
    0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
];

impl DemoEncryptor {
    pub fn new() -> Self {
        let key = Key::<Aes256Gcm>::from_slice(&DEMO_KEY_BYTES);
        Self {
            cipher: Aes256Gcm::new(key),
        }
    }
}

impl CaptureEncryptor for DemoEncryptor {
    fn encrypt(&self, data: &[u8]) -> Result<Vec<u8>, String> {
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        let ciphertext = self
            .cipher
            .encrypt(&nonce, data)
            .map_err(|e| format!("AES-GCM encryption failed: {}", e))?;

        // Combined format: nonce (12B) || ciphertext || tag (16B)
        // aes-gcm already appends the tag to ciphertext, so just prepend nonce.
        let mut combined = Vec::with_capacity(nonce.len() + ciphertext.len());
        combined.extend_from_slice(&nonce);
        combined.extend_from_slice(&ciphertext);
        Ok(combined)
    }

    fn key_metadata(&self) -> HashMap<String, String> {
        let mut meta = HashMap::new();
        meta.insert("keyId".to_string(), "demo-key-v1".to_string());
        meta.insert("algorithm".to_string(), self.algorithm().to_string());
        meta.insert(
            "warning".to_string(),
            "DEMO KEY — NOT FOR PRODUCTION".to_string(),
        );
        meta
    }

    fn algorithm(&self) -> &str {
        "AES-256-GCM"
    }

    fn clone_box(&self) -> Box<dyn CaptureEncryptor> {
        Box::new(DemoEncryptor::new())
    }
}
