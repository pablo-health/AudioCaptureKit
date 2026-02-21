use std::fs::{self, File};
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::models::config::CaptureConfiguration;
use crate::models::error::CaptureError;
use crate::processing::wav_format;
use crate::traits::encryptor::CaptureEncryptor;

/// Streaming WAV file writer with optional AES-256-GCM chunk encryption.
///
/// Ports Swift's `EncryptedFileWriter` actor. In Rust, protect with
/// `Mutex` for cross-thread access.
///
/// ## File Format
///
/// **Plaintext (no encryptor):**
/// ```text
/// [44-byte WAV header]
/// [raw 16-bit PCM data...]
/// ```
///
/// **Encrypted (with encryptor):**
/// ```text
/// [44-byte WAV header — unencrypted]
/// [Chunk 1: 4-byte LE length | sealed box (nonce + ciphertext + tag)]
/// [Chunk 2: ...]
/// ...
/// ```
pub struct EncryptedFileWriter {
    file_path: PathBuf,
    encryptor: Option<Box<dyn CaptureEncryptor>>,
    file: Option<File>,
    total_bytes_written: u64,
    is_open: bool,
}

impl EncryptedFileWriter {
    pub fn new(file_path: PathBuf, encryptor: Option<Box<dyn CaptureEncryptor>>) -> Self {
        Self {
            file_path,
            encryptor,
            file: None,
            total_bytes_written: 0,
            is_open: false,
        }
    }

    /// Open the file and write the initial 44-byte WAV header.
    pub fn open(&mut self, config: &CaptureConfiguration) -> Result<(), CaptureError> {
        if self.is_open {
            return Ok(());
        }

        // Ensure output directory exists
        if let Some(parent) = self.file_path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| CaptureError::StorageError(format!("failed to create directory: {}", e)))?;
        }

        let file = File::create(&self.file_path)
            .map_err(|e| CaptureError::StorageError(format!("failed to create file: {}", e)))?;

        self.file = Some(file);

        let header = wav_format::generate_wav_header(
            config.sample_rate as u32,
            config.bit_depth,
            config.channels,
            0, // data size placeholder — updated on close
        );

        self.write_raw(&header)?;
        self.is_open = true;
        Ok(())
    }

    /// Write audio data, optionally encrypting it.
    ///
    /// In encrypted mode, writes: `[4-byte chunk length (LE)] [sealed box]`
    /// In plaintext mode, writes raw PCM data directly.
    pub fn write(&mut self, data: &[u8]) -> Result<(), CaptureError> {
        if !self.is_open {
            return Err(CaptureError::StorageError("file is not open for writing".into()));
        }

        if let Some(ref encryptor) = self.encryptor {
            let encrypted = encryptor
                .encrypt(data)
                .map_err(|e| CaptureError::EncryptionFailed(format!("chunk encryption failed: {}", e)))?;

            // Write 4-byte length prefix + encrypted chunk
            let chunk_length = (encrypted.len() as u32).to_le_bytes();
            self.write_raw(&chunk_length)?;
            self.write_raw(&encrypted)?;
        } else {
            self.write_raw(data)?;
        }

        Ok(())
    }

    /// Finalize the file: update WAV header sizes, compute SHA-256 checksum.
    ///
    /// Optionally patches the sample rate if Bluetooth HFP negotiation changed it.
    pub fn close(
        &mut self,
        actual_sample_rate: Option<f64>,
        channels: u16,
        bit_depth: u16,
    ) -> Result<String, CaptureError> {
        if !self.is_open {
            return Err(CaptureError::StorageError("file is not open".into()));
        }

        let file = self.file.as_mut().unwrap();
        let data_size = self.total_bytes_written - wav_format::WAV_HEADER_SIZE as u64;

        // Patch RIFF chunk size at offset 4
        file.seek(SeekFrom::Start(4))
            .map_err(|e| CaptureError::StorageError(e.to_string()))?;
        let file_size = (self.total_bytes_written - 8) as u32;
        file.write_all(&file_size.to_le_bytes())
            .map_err(|e| CaptureError::StorageError(e.to_string()))?;

        // Optionally patch sample rate (for HFP rate changes)
        if let Some(rate) = actual_sample_rate {
            let sample_rate = rate as u32;
            let byte_rate = sample_rate * channels as u32 * bit_depth as u32 / 8;
            let block_align = channels * bit_depth / 8;

            file.seek(SeekFrom::Start(24))
                .map_err(|e| CaptureError::StorageError(e.to_string()))?;
            file.write_all(&sample_rate.to_le_bytes())
                .map_err(|e| CaptureError::StorageError(e.to_string()))?;
            file.write_all(&byte_rate.to_le_bytes())
                .map_err(|e| CaptureError::StorageError(e.to_string()))?;
            file.write_all(&block_align.to_le_bytes())
                .map_err(|e| CaptureError::StorageError(e.to_string()))?;
        }

        // Patch data size at offset 40
        file.seek(SeekFrom::Start(40))
            .map_err(|e| CaptureError::StorageError(e.to_string()))?;
        let data_size_u32 = data_size as u32;
        file.write_all(&data_size_u32.to_le_bytes())
            .map_err(|e| CaptureError::StorageError(e.to_string()))?;

        // Flush and close file
        file.flush().map_err(|e| CaptureError::StorageError(e.to_string()))?;
        self.file = None;
        self.is_open = false;

        // Compute SHA-256 checksum of the completed file
        let checksum = sha256_file(&self.file_path)?;
        Ok(checksum)
    }

    /// Total bytes written so far (including WAV header).
    pub fn bytes_written(&self) -> u64 {
        self.total_bytes_written
    }

    /// Path of the output file.
    pub fn file_path(&self) -> &Path {
        &self.file_path
    }

    fn write_raw(&mut self, data: &[u8]) -> Result<(), CaptureError> {
        let file = self
            .file
            .as_mut()
            .ok_or_else(|| CaptureError::StorageError("file is not open".into()))?;
        file.write_all(data)
            .map_err(|e| CaptureError::StorageError(format!("write failed: {}", e)))?;
        self.total_bytes_written += data.len() as u64;
        Ok(())
    }
}

/// Compute SHA-256 hex digest of a file.
fn sha256_file(path: &Path) -> Result<String, CaptureError> {
    let data =
        fs::read(path).map_err(|e| CaptureError::StorageError(format!("failed to read file for checksum: {}", e)))?;
    let digest = Sha256::digest(&data);
    Ok(hex_encode(&digest))
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    struct NullEncryptor;

    impl CaptureEncryptor for NullEncryptor {
        fn encrypt(&self, data: &[u8]) -> Result<Vec<u8>, String> {
            // Simple test encryptor: prefix with 12 "nonce" bytes + data + 16 "tag" bytes
            let mut result = vec![0xAA; 12]; // fake nonce
            result.extend_from_slice(data);
            result.extend_from_slice(&[0xBB; 16]); // fake tag
            Ok(result)
        }

        fn key_metadata(&self) -> HashMap<String, String> {
            HashMap::from([("keyId".to_string(), "test-key".to_string())])
        }

        fn algorithm(&self) -> &str {
            "TEST-ENCRYPTOR"
        }

        fn clone_box(&self) -> Box<dyn CaptureEncryptor> {
            Box::new(NullEncryptor)
        }
    }

    fn temp_file_path(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("audio_capture_test_{}", name))
    }

    #[test]
    fn write_plain_wav() {
        let path = temp_file_path("plain.wav");
        let config = CaptureConfiguration {
            sample_rate: 48000.0,
            bit_depth: 16,
            channels: 2,
            ..Default::default()
        };

        let mut writer = EncryptedFileWriter::new(path.clone(), None);
        writer.open(&config).unwrap();

        // Write some PCM data (4 stereo frames = 16 bytes)
        let pcm = vec![0u8; 16];
        writer.write(&pcm).unwrap();

        let checksum = writer.close(None, 2, 16).unwrap();
        assert!(!checksum.is_empty());

        // Verify file structure
        let file_data = fs::read(&path).unwrap();
        assert_eq!(file_data.len(), 44 + 16); // header + data

        // Verify WAV header magic
        assert_eq!(&file_data[0..4], b"RIFF");
        assert_eq!(&file_data[8..12], b"WAVE");

        // Verify data size in header
        let data_size = u32::from_le_bytes([file_data[40], file_data[41], file_data[42], file_data[43]]);
        assert_eq!(data_size, 16);

        fs::remove_file(&path).ok();
    }

    #[test]
    fn write_encrypted_wav() {
        let path = temp_file_path("encrypted.enc.wav");
        let config = CaptureConfiguration {
            sample_rate: 48000.0,
            bit_depth: 16,
            channels: 2,
            ..Default::default()
        };

        let encryptor = Box::new(NullEncryptor) as Box<dyn CaptureEncryptor>;
        let mut writer = EncryptedFileWriter::new(path.clone(), Some(encryptor));
        writer.open(&config).unwrap();

        // Write 8 bytes of PCM data
        let pcm = vec![0x42u8; 8];
        writer.write(&pcm).unwrap();

        let _checksum = writer.close(None, 2, 16).unwrap();

        let file_data = fs::read(&path).unwrap();

        // Header (44) + 4-byte length + 12 nonce + 8 data + 16 tag = 84
        let expected_chunk_size = 12 + 8 + 16; // 36
        assert_eq!(file_data.len(), 44 + 4 + expected_chunk_size);

        // Verify chunk length prefix
        let chunk_len = u32::from_le_bytes([file_data[44], file_data[45], file_data[46], file_data[47]]);
        assert_eq!(chunk_len, expected_chunk_size as u32);

        fs::remove_file(&path).ok();
    }

    #[test]
    fn close_patches_sample_rate() {
        let path = temp_file_path("hfp_rate.wav");
        let config = CaptureConfiguration {
            sample_rate: 48000.0,
            bit_depth: 16,
            channels: 2,
            ..Default::default()
        };

        let mut writer = EncryptedFileWriter::new(path.clone(), None);
        writer.open(&config).unwrap();
        writer.write(&vec![0u8; 16]).unwrap();
        writer.close(Some(16000.0), 2, 16).unwrap();

        let file_data = fs::read(&path).unwrap();
        let sample_rate = u32::from_le_bytes([file_data[24], file_data[25], file_data[26], file_data[27]]);
        assert_eq!(sample_rate, 16000);

        let byte_rate = u32::from_le_bytes([file_data[28], file_data[29], file_data[30], file_data[31]]);
        assert_eq!(byte_rate, 64000); // 16000 * 2 * 2

        fs::remove_file(&path).ok();
    }
}
