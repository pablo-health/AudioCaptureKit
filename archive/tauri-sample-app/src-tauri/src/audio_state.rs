use std::sync::Arc;

use parking_lot::Mutex;
use serde::Serialize;
use tauri::{AppHandle, Emitter};

use audio_capture_core::{
    AudioLevels, AudioSource, CaptureDelegate, CaptureError, CaptureState,
    CompositeSession, RecordingResult,
};
use audio_capture_core::models::audio_models::CaptureSessionDiagnostics;
use audio_capture_windows::{WasapiLoopbackCapture, WasapiMicCapture};

type Session = CompositeSession<WasapiMicCapture, WasapiLoopbackCapture>;

/// Tauri-managed state holding the active capture session.
pub struct AudioState {
    pub session: Mutex<Option<Session>>,
}

impl AudioState {
    pub fn new() -> Self {
        Self {
            session: Mutex::new(None),
        }
    }
}

/// CaptureDelegate that forwards events to the React frontend via Tauri events.
pub struct TauriDelegate {
    app: AppHandle,
}

impl TauriDelegate {
    pub fn new(app: AppHandle) -> Arc<Self> {
        Arc::new(Self { app })
    }
}

// -- Event payloads --

#[derive(Clone, Serialize)]
struct StateChangedPayload {
    state: String,
    duration_secs: f64,
}

#[derive(Clone, Serialize)]
struct LevelsPayload {
    mic_level: f32,
    system_level: f32,
    peak_mic_level: f32,
    peak_system_level: f32,
}

#[derive(Clone, Serialize)]
struct ErrorPayload {
    message: String,
}

#[derive(Clone, Serialize)]
struct CaptureFinishedPayload {
    file_path: String,
    duration_secs: f64,
    is_encrypted: bool,
    checksum: String,
}

impl CaptureDelegate for TauriDelegate {
    fn on_state_changed(&self, state: &CaptureState) {
        let (name, duration) = match state {
            CaptureState::Idle => ("idle", 0.0),
            CaptureState::Configuring => ("configuring", 0.0),
            CaptureState::Ready => ("ready", 0.0),
            CaptureState::Capturing { duration_secs } => ("capturing", *duration_secs),
            CaptureState::Paused { duration_secs } => ("paused", *duration_secs),
            CaptureState::Stopping => ("stopping", 0.0),
            CaptureState::Completed(r) => ("completed", r.duration_secs),
            CaptureState::Failed(_) => ("failed", 0.0),
        };
        let _ = self.app.emit(
            "audio://state-changed",
            StateChangedPayload {
                state: name.to_string(),
                duration_secs: duration,
            },
        );
    }

    fn on_levels_updated(&self, levels: &AudioLevels) {
        let _ = self.app.emit(
            "audio://levels-updated",
            LevelsPayload {
                mic_level: levels.mic_level,
                system_level: levels.system_level,
                peak_mic_level: levels.peak_mic_level,
                peak_system_level: levels.peak_system_level,
            },
        );
    }

    fn on_error(&self, error: &CaptureError) {
        let _ = self.app.emit(
            "audio://error",
            ErrorPayload {
                message: error.to_string(),
            },
        );
    }

    fn on_capture_finished(&self, result: &RecordingResult) {
        let _ = self.app.emit(
            "audio://capture-finished",
            CaptureFinishedPayload {
                file_path: result.file_path.to_string_lossy().to_string(),
                duration_secs: result.duration_secs,
                is_encrypted: result.metadata.is_encrypted,
                checksum: result.checksum.clone(),
            },
        );
    }
}

// -- Helper to convert AudioSource to a serializable type --

#[derive(Clone, Serialize)]
pub struct DeviceInfo {
    pub id: String,
    pub name: String,
    pub is_default: bool,
}

impl From<AudioSource> for DeviceInfo {
    fn from(src: AudioSource) -> Self {
        Self {
            id: src.id,
            name: src.name,
            is_default: src.is_default,
        }
    }
}

/// Serializable diagnostics snapshot.
#[derive(Clone, Serialize)]
pub struct DiagnosticsInfo {
    pub mic_callback_count: u64,
    pub system_callback_count: u64,
    pub mic_samples_total: u64,
    pub system_samples_total: u64,
    pub mic_format: String,
    pub system_format: String,
    pub bytes_written: u64,
    pub mix_cycles: u64,
}

impl From<CaptureSessionDiagnostics> for DiagnosticsInfo {
    fn from(d: CaptureSessionDiagnostics) -> Self {
        Self {
            mic_callback_count: d.mic_callback_count,
            system_callback_count: d.system_callback_count,
            mic_samples_total: d.mic_samples_total,
            system_samples_total: d.system_samples_total,
            mic_format: d.mic_format,
            system_format: d.system_format,
            bytes_written: d.bytes_written,
            mix_cycles: d.mix_cycles,
        }
    }
}
