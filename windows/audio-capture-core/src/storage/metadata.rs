use std::fs;
use std::path::Path;

use crate::models::error::CaptureError;
use crate::models::recording_result::RecordingMetadata;

/// Write recording metadata as a JSON sidecar file.
///
/// Creates `{recording_path}.metadata.json` alongside the recording.
pub fn write_metadata(metadata: &RecordingMetadata, recording_path: &Path) -> Result<(), CaptureError> {
    let metadata_path = recording_path.with_extension("metadata.json");
    let json = serde_json::to_string_pretty(metadata)
        .map_err(|e| CaptureError::StorageError(format!("failed to serialize metadata: {}", e)))?;
    fs::write(&metadata_path, json)
        .map_err(|e| CaptureError::StorageError(format!("failed to write metadata: {}", e)))?;
    Ok(())
}

/// Read recording metadata from a JSON sidecar file.
pub fn read_metadata(recording_path: &Path) -> Result<RecordingMetadata, CaptureError> {
    let metadata_path = recording_path.with_extension("metadata.json");
    let json = fs::read_to_string(&metadata_path)
        .map_err(|e| CaptureError::StorageError(format!("failed to read metadata: {}", e)))?;
    let metadata: RecordingMetadata = serde_json::from_str(&json)
        .map_err(|e| CaptureError::StorageError(format!("failed to parse metadata: {}", e)))?;
    Ok(metadata)
}
