use std::path::PathBuf;

use super::super::traits::encryptor::CaptureEncryptor;
use super::mixing_strategy::MixingStrategy;

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

    /// Determines how mic and system audio are combined into the output WAV.
    /// Default is `MixingStrategy::Blended` to preserve existing behavior.
    pub mixing_strategy: MixingStrategy,

    /// When true, writes raw PCM sidecar files alongside the WAV:
    /// - `{name}_mic.pcm`    -- mono mic, signed 16-bit LE, no header
    /// - `{name}_system.pcm` -- interleaved stereo system audio, signed 16-bit LE, no header
    /// Default: false.
    pub export_raw_pcm: bool,
}

impl CaptureConfiguration {
    pub fn validate(&self) -> Result<(), String> {
        if self.sample_rate <= 0.0 {
            return Err("sample rate must be positive".into());
        }
        if ![16, 24, 32].contains(&self.bit_depth) {
            return Err(format!("unsupported bit depth: {}", self.bit_depth));
        }
        if !(1..=4).contains(&self.channels) {
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
            mixing_strategy: MixingStrategy::default(),
            export_raw_pcm: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn export_raw_pcm_defaults_false() {
        let config = CaptureConfiguration::default();
        assert!(!config.export_raw_pcm);
    }

    #[test]
    fn mixing_strategy_defaults_to_blended() {
        let config = CaptureConfiguration::default();
        assert_eq!(config.mixing_strategy, MixingStrategy::Blended);
    }

    #[test]
    fn channels_valid_range() {
        for ch in 1u16..=4 {
            let mut config = CaptureConfiguration::default();
            config.channels = ch;
            assert!(config.validate().is_ok(), "channel count {ch} should be valid");
        }
    }

    #[test]
    fn channels_invalid_zero_and_five() {
        for ch in [0u16, 5] {
            let mut config = CaptureConfiguration::default();
            config.channels = ch;
            assert!(config.validate().is_err(), "channel count {ch} should be invalid");
        }
    }
}
