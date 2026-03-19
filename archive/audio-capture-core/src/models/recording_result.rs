use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use super::audio_models::{AudioChannel, AudioTrack, AudioTrackType, ChannelLayout};

/// Result returned when a capture session completes successfully.
#[derive(Debug, Clone, PartialEq)]
pub struct RecordingResult {
    pub file_path: PathBuf,
    pub duration_secs: f64,
    pub metadata: RecordingMetadata,
    pub checksum: String,
    /// Paths of PCM sidecar files. [0] = mic (mono), [1] = system (stereo).
    /// Uses `.enc.pcm` extension when encrypted. Empty unless export_raw_pcm was enabled.
    pub raw_pcm_file_paths: Vec<PathBuf>,
}

/// Metadata stored alongside (or embedded in) a recording.
///
/// Serializable for JSON export to the backend.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordingMetadata {
    pub id: String,
    pub duration_secs: f64,
    pub file_path: String,
    pub checksum: String,
    pub is_encrypted: bool,
    pub created_at: String,
    pub tracks: Vec<AudioTrack>,
    pub encryption_algorithm: Option<String>,
    pub encryption_key_id: Option<String>,
    pub channel_layout: ChannelLayout,
}

impl RecordingMetadata {
    /// Creates metadata for a standard mic + system stereo recording.
    pub fn new_stereo(
        duration_secs: f64,
        file_path: &str,
        checksum: &str,
        is_encrypted: bool,
        encryption_algorithm: Option<String>,
        encryption_key_id: Option<String>,
    ) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            duration_secs,
            file_path: file_path.to_string(),
            checksum: checksum.to_string(),
            is_encrypted,
            created_at: chrono::Utc::now().to_rfc3339(),
            tracks: vec![
                AudioTrack::new(AudioTrackType::Mic, AudioChannel::Center),
                AudioTrack::new(AudioTrackType::System, AudioChannel::Stereo),
            ],
            encryption_algorithm,
            encryption_key_id,
            channel_layout: ChannelLayout::Blended,
        }
    }

    /// Creates metadata for a separated-channel mic+system recording.
    pub fn new_separated(
        duration_secs: f64,
        file_path: &str,
        checksum: &str,
        is_encrypted: bool,
        encryption_algorithm: Option<String>,
        encryption_key_id: Option<String>,
    ) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            duration_secs,
            file_path: file_path.to_string(),
            checksum: checksum.to_string(),
            is_encrypted,
            created_at: chrono::Utc::now().to_rfc3339(),
            tracks: vec![
                AudioTrack::with_label(AudioTrackType::Mic, AudioChannel::Left, "Mic (Local)"),
                AudioTrack::with_label(
                    AudioTrackType::System,
                    AudioChannel::Right,
                    "System (Remote, mono-fold)",
                ),
            ],
            encryption_algorithm,
            encryption_key_id,
            channel_layout: ChannelLayout::SeparatedStereo,
        }
    }
}
