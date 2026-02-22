use crate::models::audio_models::AudioLevels;
use crate::models::error::CaptureError;
use crate::models::recording_result::RecordingResult;
use crate::models::state::CaptureState;

/// Event delegate for capture session notifications.
///
/// Equivalent to Swift's `AudioCaptureDelegate` protocol.
/// All methods are called from the processing thread, not the UI thread.
/// Implementations should marshal to the UI thread if needed.
pub trait CaptureDelegate: Send + Sync {
    /// Called when the session state changes.
    fn on_state_changed(&self, state: &CaptureState);

    /// Called periodically with updated audio levels.
    fn on_levels_updated(&self, levels: &AudioLevels);

    /// Called when an error occurs during capture.
    fn on_error(&self, error: &CaptureError);

    /// Called when capture completes and the file is finalized.
    fn on_capture_finished(&self, result: &RecordingResult);
}
