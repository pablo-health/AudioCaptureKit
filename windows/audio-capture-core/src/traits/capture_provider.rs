use std::sync::Arc;

use crate::models::audio_models::AudioSource;
use crate::models::error::CaptureError;

/// Callback invoked when an audio buffer is available.
///
/// Parameters:
/// - `samples`: Interleaved f32 samples (mono for mic, stereo for system).
/// - `sample_rate`: The actual sample rate of the delivered audio.
/// - `channels`: Number of channels (1 = mono, 2 = stereo interleaved).
pub type AudioBufferCallback =
    Arc<dyn Fn(&[f32], f64, u16) + Send + Sync + 'static>;

/// Interface for platform-specific audio capture sources.
///
/// Equivalent to Swift's `AudioCaptureProvider` protocol.
/// Implemented by:
/// - `WasapiMicCapture` (Windows)
/// - `WasapiLoopbackCapture` (Windows)
/// - Future: `CoreAudioTapCapture`, `AVFoundationMicCapture` (macOS)
pub trait CaptureProvider: Send + Sync {
    /// Whether this capture source is currently available.
    fn is_available(&self) -> bool;

    /// Start capturing audio, delivering buffers via `callback`.
    ///
    /// The callback fires on a dedicated audio thread — keep processing minimal.
    fn start(&mut self, callback: AudioBufferCallback) -> Result<(), CaptureError>;

    /// Stop capturing and release resources.
    fn stop(&mut self) -> Result<(), CaptureError>;

    /// Information about the audio device backing this provider.
    fn device_info(&self) -> AudioSource;
}
