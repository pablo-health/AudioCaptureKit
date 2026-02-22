use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, State};

use audio_capture_core::{CaptureConfiguration, CompositeSession};
use audio_capture_windows::{DeviceEnumerator, WasapiLoopbackCapture, WasapiMicCapture};

use crate::audio_state::{AudioState, DeviceInfo, DiagnosticsInfo, TauriDelegate};
use crate::demo_encryptor::DemoEncryptor;

/// Config received from the React frontend.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingConfig {
    pub mic_device_id: Option<String>,
    pub enable_mic: bool,
    pub enable_system: bool,
    pub encrypt: bool,
}

/// Info about a saved recording, returned to the frontend.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingInfo {
    pub file_path: String,
    pub file_name: String,
    pub size_bytes: u64,
    pub is_encrypted: bool,
    pub created_at: String,
}

fn recordings_dir() -> PathBuf {
    let dir = dirs_next::document_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("AudioCaptureKit Recordings");
    fs::create_dir_all(&dir).ok();
    dir
}

#[tauri::command]
pub fn list_capture_devices() -> Result<Vec<DeviceInfo>, String> {
    let enumerator = DeviceEnumerator::new().map_err(|e| e.to_string())?;
    let devices = enumerator
        .list_capture_devices()
        .map_err(|e| e.to_string())?;
    Ok(devices.into_iter().map(DeviceInfo::from).collect())
}

#[tauri::command]
pub fn list_render_devices() -> Result<Vec<DeviceInfo>, String> {
    let enumerator = DeviceEnumerator::new().map_err(|e| e.to_string())?;
    let devices = enumerator
        .list_render_devices()
        .map_err(|e| e.to_string())?;
    Ok(devices.into_iter().map(DeviceInfo::from).collect())
}

#[tauri::command]
pub fn start_recording(
    config: RecordingConfig,
    app: AppHandle,
    state: State<'_, AudioState>,
) -> Result<(), String> {
    let mut session_guard = state.session.lock();

    // Drop any previous session
    *session_guard = None;

    // Create capture providers
    let mic = if let Some(ref device_id) = config.mic_device_id {
        WasapiMicCapture::with_device(device_id.clone(), String::new(), None)
    } else {
        WasapiMicCapture::default_device().map_err(|e| e.to_string())?
    };
    let loopback = WasapiLoopbackCapture::default_device().map_err(|e| e.to_string())?;

    let mut session = CompositeSession::new(mic, loopback);

    // Set delegate for Tauri event forwarding
    session.set_delegate(TauriDelegate::new(app));

    // Build capture configuration
    let output_dir = recordings_dir();
    let encryptor: Option<Box<dyn audio_capture_core::CaptureEncryptor>> = if config.encrypt {
        Some(Box::new(DemoEncryptor::new()))
    } else {
        None
    };

    let capture_config = CaptureConfiguration {
        sample_rate: 48000.0,
        bit_depth: 16,
        channels: 2,
        encryptor,
        output_directory: output_dir,
        max_duration_secs: None,
        mic_device_id: config.mic_device_id,
        enable_mic_capture: config.enable_mic,
        enable_system_capture: config.enable_system,
    };

    session.configure(capture_config).map_err(|e| e.to_string())?;
    session.start_capture().map_err(|e| e.to_string())?;

    *session_guard = Some(session);
    Ok(())
}

#[tauri::command]
pub fn pause_recording(state: State<'_, AudioState>) -> Result<(), String> {
    let mut session_guard = state.session.lock();
    let session = session_guard
        .as_mut()
        .ok_or("no active session")?;
    session.pause_capture().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn resume_recording(state: State<'_, AudioState>) -> Result<(), String> {
    let mut session_guard = state.session.lock();
    let session = session_guard
        .as_mut()
        .ok_or("no active session")?;
    session.resume_capture().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn stop_recording(state: State<'_, AudioState>) -> Result<RecordingInfo, String> {
    let mut session_guard = state.session.lock();
    let session = session_guard
        .as_mut()
        .ok_or("no active session")?;

    let result = session.stop_capture().map_err(|e| e.to_string())?;

    let file_path = result.file_path.to_string_lossy().to_string();
    let file_name = result
        .file_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();

    let size_bytes = fs::metadata(&result.file_path)
        .map(|m| m.len())
        .unwrap_or(0);

    // Drop session so it resets to idle
    *session_guard = None;

    Ok(RecordingInfo {
        file_path,
        file_name,
        size_bytes,
        is_encrypted: result.metadata.is_encrypted,
        created_at: result.metadata.created_at,
    })
}

#[tauri::command]
pub fn get_recordings() -> Result<Vec<RecordingInfo>, String> {
    let dir = recordings_dir();
    let mut recordings = Vec::new();

    let entries = fs::read_dir(&dir).map_err(|e| e.to_string())?;
    for entry in entries.flatten() {
        let path = entry.path();
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();

        // Only list .wav and .enc.wav files
        if !name.ends_with(".wav") {
            continue;
        }

        let meta = fs::metadata(&path).map_err(|e| e.to_string())?;
        let created = meta
            .created()
            .ok()
            .and_then(|t| {
                let dt: chrono::DateTime<chrono::Utc> = t.into();
                Some(dt.to_rfc3339())
            })
            .unwrap_or_default();

        recordings.push(RecordingInfo {
            file_path: path.to_string_lossy().to_string(),
            file_name: name.clone(),
            size_bytes: meta.len(),
            is_encrypted: name.contains(".enc."),
            created_at: created,
        });
    }

    // Sort newest first
    recordings.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    Ok(recordings)
}

#[tauri::command]
pub fn delete_recording(path: String) -> Result<(), String> {
    let target = fs::canonicalize(&path).map_err(|e| e.to_string())?;
    let allowed_dir = fs::canonicalize(recordings_dir()).map_err(|e| e.to_string())?;

    if !target.starts_with(&allowed_dir) {
        return Err("Path is outside the recordings directory".into());
    }

    fs::remove_file(&target).map_err(|e| e.to_string())?;

    // Also delete metadata sidecar if it exists
    let meta_path = format!("{}.metadata.json", path);
    let _ = fs::remove_file(&meta_path);

    Ok(())
}

#[tauri::command]
pub fn get_diagnostics(state: State<'_, AudioState>) -> Result<DiagnosticsInfo, String> {
    let session_guard = state.session.lock();
    let session = session_guard
        .as_ref()
        .ok_or("no active session")?;
    Ok(DiagnosticsInfo::from(session.diagnostics()))
}
