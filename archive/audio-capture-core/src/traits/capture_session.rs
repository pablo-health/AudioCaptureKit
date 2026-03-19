use crate::models::audio_models::{AudioLevels, AudioSource};
use crate::models::config::CaptureConfiguration;
use crate::models::error::CaptureError;
use crate::models::recording_result::RecordingResult;
use crate::models::state::CaptureState;

/// Main capture session interface.
///
/// Equivalent to Swift's `AudioCaptureSession` protocol.
/// Orchestrates mic + system audio capture, mixing, and encrypted file output.
pub trait CaptureSession: Send + Sync {
    /// Current session state.
    fn state(&self) -> CaptureState;

    /// Current audio levels (RMS + peak).
    fn current_levels(&self) -> AudioLevels;

    /// List available audio sources (microphones and system outputs).
    fn available_audio_sources(&self) -> Result<Vec<AudioSource>, CaptureError>;

    /// Apply configuration. Transitions: idle → configuring → ready.
    fn configure(&mut self, config: CaptureConfiguration) -> Result<(), CaptureError>;

    /// Start capture. Transitions: ready → capturing.
    fn start_capture(&mut self) -> Result<(), CaptureError>;

    /// Pause capture. Transitions: capturing → paused.
    fn pause_capture(&mut self) -> Result<(), CaptureError>;

    /// Resume capture. Transitions: paused → capturing.
    fn resume_capture(&mut self) -> Result<(), CaptureError>;

    /// Stop capture and finalize the recording file.
    /// Transitions: capturing/paused → stopping → completed/failed.
    fn stop_capture(&mut self) -> Result<RecordingResult, CaptureError>;
}
