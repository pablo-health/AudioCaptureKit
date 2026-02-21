use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use super::audio_models::{AudioTrack, AudioTrackType, AudioChannel};

/// Result returned when a capture session completes successfully.
#[derive(Debug, Clone, PartialEq)]
pub struct RecordingResult {
    pub file_path: PathBuf,
    pub duration_secs: f64,
    pub metadata: RecordingMetadata,
    pub checksum: String,
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
                AudioTrack {
                    track_type: AudioTrackType::Mic,
                    channel: AudioChannel::Center,
                },
                AudioTrack {
                    track_type: AudioTrackType::System,
                    channel: AudioChannel::Stereo,
                },
            ],
            encryption_algorithm,
            encryption_key_id,
        }
    }
}
