use serde::{Deserialize, Serialize};

/// Type of audio source.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AudioTrackType {
    Mic,
    System,
}

/// Audio channel layout.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum AudioChannel {
    #[serde(rename = "L")]
    Left,
    #[serde(rename = "R")]
    Right,
    #[serde(rename = "C")]
    Center,
    #[serde(rename = "LR")]
    Stereo,
}

/// An audio track in a recording (e.g., mic center, system stereo).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AudioTrack {
    #[serde(rename = "type")]
    pub track_type: AudioTrackType,
    pub channel: AudioChannel,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

impl AudioTrack {
    pub fn new(track_type: AudioTrackType, channel: AudioChannel) -> Self {
        Self { track_type, channel, label: None }
    }

    pub fn with_label(track_type: AudioTrackType, channel: AudioChannel, label: impl Into<String>) -> Self {
        Self { track_type, channel, label: Some(label.into()) }
    }
}

/// Records the actual WAV channel layout for downstream decoders.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ChannelLayout {
    /// Mic mixed into both channels (legacy/blended strategy).
    #[default]
    Blended,
    /// Ch1 (Left) = mic only, Ch2 (Right) = system audio mono-folded (L+R)/2.
    SeparatedStereo,
    /// Single mono channel.
    Mono,
}

/// Raw per-channel audio samples from one processing cycle.
///
/// `system_samples` is full interleaved stereo [L0, R0, L1, R1, ...].
/// The library does not fold it to mono.
#[derive(Debug, Clone)]
pub struct ChannelBuffers {
    /// Mono microphone samples. Empty when mic capture is disabled.
    pub mic_samples: Vec<f32>,

    /// Interleaved stereo system audio [L0, R0, L1, R1, ...].
    /// Empty when system capture is disabled.
    pub system_samples: Vec<f32>,

    /// Sample rate of both arrays, in Hz.
    pub sample_rate: f64,

    /// Unix timestamp (seconds since epoch) at start of buffer window.
    pub timestamp_unix_secs: f64,
}

/// Transport type for an audio device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AudioTransportType {
    BuiltIn,
    Bluetooth,
    BluetoothLE,
    Usb,
    Virtual,
    Unknown,
}

/// An audio device available for capture or playback.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioSource {
    pub id: String,
    pub name: String,
    pub source_type: AudioTrackType,
    pub is_default: bool,
    pub transport_type: Option<AudioTransportType>,
}

/// Real-time audio level metering (RMS and peak, 0.0–1.0).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AudioLevels {
    pub mic_level: f32,
    pub system_level: f32,
    pub peak_mic_level: f32,
    pub peak_system_level: f32,
}

impl Default for AudioLevels {
    fn default() -> Self {
        Self {
            mic_level: 0.0,
            system_level: 0.0,
            peak_mic_level: 0.0,
            peak_system_level: 0.0,
        }
    }
}

/// Diagnostics for debugging capture sessions.
#[derive(Debug, Clone, Default)]
pub struct CaptureSessionDiagnostics {
    pub mic_callback_count: u64,
    pub system_callback_count: u64,
    pub mic_samples_total: u64,
    pub system_samples_total: u64,
    pub mic_format: String,
    pub system_format: String,
    pub bytes_written: u64,
    pub mix_cycles: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channel_layout_default_is_blended() {
        let layout = ChannelLayout::default();
        assert_eq!(layout, ChannelLayout::Blended);
    }

    #[test]
    fn channel_layout_json_round_trip() {
        let layout = ChannelLayout::SeparatedStereo;
        let json = serde_json::to_string(&layout).unwrap();
        let decoded: ChannelLayout = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, ChannelLayout::SeparatedStereo);
    }

    #[test]
    fn audio_track_label_omitted_when_none() {
        let track = AudioTrack::new(AudioTrackType::Mic, AudioChannel::Left);
        let json = serde_json::to_string(&track).unwrap();
        assert!(!json.contains("label"));
    }

    #[test]
    fn channel_buffers_system_samples_is_stereo_interleaved() {
        // Document the contract: system_samples.len() must be even
        let system = vec![0.1f32, 0.2, 0.3, 0.4]; // 2 stereo frames
        let buffers = ChannelBuffers {
            mic_samples: vec![],
            system_samples: system.clone(),
            sample_rate: 48000.0,
            timestamp_unix_secs: 0.0,
        };
        assert_eq!(buffers.system_samples.len() % 2, 0);
    }
}
