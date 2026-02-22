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
