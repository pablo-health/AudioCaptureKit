//! # audio-capture-core
//!
//! Platform-agnostic audio capture core library.
//!
//! Provides mixing, buffering, encryption, WAV I/O, and session orchestration.
//! Platform-specific backends (Windows WASAPI, macOS Core Audio) implement
//! the `CaptureProvider` trait and plug into the generic `CompositeSession`.
//!
//! ## Architecture
//!
//! ```text
//! audio-capture-core (this crate)
//! ├── traits/       ← CaptureProvider, CaptureSession, CaptureDelegate, CaptureEncryptor
//! ├── models/       ← CaptureError, CaptureState, CaptureConfiguration, AudioSource, etc.
//! ├── processing/   ← StereoMixer, RingBuffer, WAV header generation
//! ├── session/      ← CompositeSession (generic orchestrator)
//! └── storage/      ← EncryptedFileWriter, metadata
//! ```

pub mod models;
pub mod processing;
pub mod session;
pub mod storage;
pub mod traits;

// Re-export key types at crate root for convenience.
pub use models::audio_models::{AudioChannel, AudioLevels, AudioSource, AudioTrack, AudioTrackType, AudioTransportType};
pub use models::config::CaptureConfiguration;
pub use models::error::CaptureError;
pub use models::recording_result::{RecordingMetadata, RecordingResult};
pub use models::state::CaptureState;
pub use processing::ring_buffer::RingBuffer;
pub use processing::stereo_mixer::StereoMixer;
pub use session::composite::CompositeSession;
pub use storage::encrypted_writer::EncryptedFileWriter;
pub use traits::capture_delegate::CaptureDelegate;
pub use traits::capture_provider::{AudioBufferCallback, CaptureProvider};
pub use traits::encryptor::CaptureEncryptor;
