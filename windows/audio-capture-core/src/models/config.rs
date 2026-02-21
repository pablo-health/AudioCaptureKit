use std::path::PathBuf;

use super::super::traits::encryptor::CaptureEncryptor;

/// Configuration for a capture session.
///
/// Maps 1:1 to Swift `CaptureConfiguration`.
#[derive(Clone)]
pub struct CaptureConfiguration {
    /// Target sample rate in Hz (default: 48000).
    pub sample_rate: f64,

    /// Bit depth for PCM output (default: 16). Valid values: 16, 24, 32.
    pub bit_depth: u16,

    /// Number of output channels (default: 2 for stereo).
    pub channels: u16,

    /// Optional encryptor for streaming AES-256-GCM encryption.
    pub encryptor: Option<Box<dyn CaptureEncryptor>>,

    /// Directory where recording files are written.
    pub output_directory: PathBuf,

    /// Maximum recording duration in seconds (None = unlimited).
    pub max_duration_secs: Option<f64>,

    /// Specific microphone device ID, or None for system default.
    pub mic_device_id: Option<String>,

    /// Enable microphone capture (default: true).
    pub enable_mic_capture: bool,

    /// Enable system audio capture (default: true).
    pub enable_system_capture: bool,
}

impl CaptureConfiguration {
    pub fn validate(&self) -> Result<(), String> {
        if self.sample_rate <= 0.0 {
            return Err("sample rate must be positive".into());
        }
        if ![16, 24, 32].contains(&self.bit_depth) {
            return Err(format!("unsupported bit depth: {}", self.bit_depth));
        }
        if ![1, 2].contains(&self.channels) {
            return Err(format!("unsupported channel count: {}", self.channels));
        }
        Ok(())
    }
}

impl Default for CaptureConfiguration {
    fn default() -> Self {
        Self {
            sample_rate: 48000.0,
            bit_depth: 16,
            channels: 2,
            encryptor: None,
            output_directory: PathBuf::from("."),
            max_duration_secs: None,
            mic_device_id: None,
            enable_mic_capture: true,
            enable_system_capture: true,
        }
    }
}
