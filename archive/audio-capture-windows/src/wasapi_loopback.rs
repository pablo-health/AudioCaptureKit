//! WASAPI loopback capture provider for system audio.
//!
//! Captures the audio mix going to a render endpoint using
//! `AUDCLNT_STREAMFLAGS_LOOPBACK`. No special permissions needed on Windows.
//!
//! ## Key Differences from macOS
//! - No entitlements, code signing, or TCC permissions required
//! - Captures audio for a specific render device (not all devices)
//! - DRM-protected audio is silenced in loopback
//! - Requires Windows 10 1703+ for event-driven mode

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use parking_lot::Mutex;
use windows::core::PCWSTR;
use windows::Win32::Media::Audio::*;
use windows::Win32::System::Com::*;
use windows::Win32::System::Threading::*;

use audio_capture_core::models::audio_models::{AudioSource, AudioTrackType};
use audio_capture_core::models::error::CaptureError;
use audio_capture_core::traits::capture_provider::{AudioBufferCallback, CaptureProvider};

/// WASAPI loopback capture for system audio.
///
/// Opens the default render endpoint with `AUDCLNT_STREAMFLAGS_LOOPBACK`
/// to capture all audio being played to that device.
pub struct WasapiLoopbackCapture {
    device_name: String,
    running: Arc<AtomicBool>,
    capture_handle: Mutex<Option<thread::JoinHandle<()>>>,
}

// SAFETY: COM objects are confined to the capture thread.
unsafe impl Send for WasapiLoopbackCapture {}
unsafe impl Sync for WasapiLoopbackCapture {}

impl WasapiLoopbackCapture {
    /// Create a loopback capture on the default render device.
    pub fn default_device() -> Result<Self, CaptureError> {
        Ok(Self {
            device_name: "System Audio (Loopback)".into(),
            running: Arc::new(AtomicBool::new(false)),
            capture_handle: Mutex::new(None),
        })
    }
}

impl CaptureProvider for WasapiLoopbackCapture {
    fn is_available(&self) -> bool {
        // WASAPI loopback is always available on Windows Vista+
        true
    }

    fn start(&mut self, callback: AudioBufferCallback) -> Result<(), CaptureError> {
        if self.running.load(Ordering::SeqCst) {
            return Err(CaptureError::ConfigurationFailed(
                "loopback capture already running".into(),
            ));
        }

        self.running.store(true, Ordering::SeqCst);
        let running = Arc::clone(&self.running);

        let handle = thread::Builder::new()
            .name("wasapi-loopback-capture".into())
            .spawn(move || {
                if let Err(e) = loopback_capture_loop(running.clone(), callback) {
                    log::error!("Loopback capture error: {}", e);
                }
                running.store(false, Ordering::SeqCst);
            })
            .map_err(|e| CaptureError::Unknown(format!("failed to spawn loopback thread: {}", e)))?;

        *self.capture_handle.lock() = Some(handle);
        Ok(())
    }

    fn stop(&mut self) -> Result<(), CaptureError> {
        self.running.store(false, Ordering::SeqCst);
        if let Some(handle) = self.capture_handle.lock().take() {
            let _ = handle.join();
        }
        Ok(())
    }

    fn device_info(&self) -> AudioSource {
        AudioSource {
            id: "system-loopback".into(),
            name: self.device_name.clone(),
            source_type: AudioTrackType::System,
            is_default: true,
            transport_type: None,
        }
    }
}

/// Main loopback capture loop running on a dedicated thread.
///
/// Sequence:
/// 1. CoInitializeEx (MTA)
/// 2. Get default render endpoint
/// 3. Activate IAudioClient
/// 4. Initialize with LOOPBACK flag in shared mode
/// 5. Get IAudioCaptureClient
/// 6. Register with MMCSS
/// 7. Start, poll for buffers
fn loopback_capture_loop(running: Arc<AtomicBool>, callback: AudioBufferCallback) -> Result<(), CaptureError> {
    unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED)
            .ok()
            .map_err(|e| CaptureError::Unknown(format!("CoInitializeEx failed: {}", e)))?;

        let _com_guard = CoUninitializeGuard;

        let enumerator: IMMDeviceEnumerator =
            CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).map_err(|_| CaptureError::DeviceNotAvailable)?;

        // Get default RENDER endpoint (not capture — loopback reads from render)
        let device = enumerator
            .GetDefaultAudioEndpoint(eRender, eConsole)
            .map_err(|_| CaptureError::DeviceNotAvailable)?;

        let audio_client: IAudioClient = device
            .Activate(CLSCTX_ALL, None)
            .map_err(|e| CaptureError::ConfigurationFailed(format!("Activate failed: {}", e)))?;

        let mix_format_ptr = audio_client
            .GetMixFormat()
            .map_err(|e| CaptureError::ConfigurationFailed(format!("GetMixFormat failed: {}", e)))?;

        let mix_format = &*mix_format_ptr;
        let sample_rate = mix_format.nSamplesPerSec as f64;
        let channels = mix_format.nChannels;

        // Initialize with LOOPBACK flag — shared mode only
        let buffer_duration = 1_000_000; // 100ms in 100ns units

        audio_client
            .Initialize(
                AUDCLNT_SHAREMODE_SHARED,
                AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_NOPERSIST,
                buffer_duration,
                0,
                mix_format,
                None,
            )
            .map_err(|e| {
                CaptureError::ConfigurationFailed(format!("IAudioClient::Initialize (loopback) failed: {}", e))
            })?;

        let capture_client: IAudioCaptureClient = audio_client
            .GetService()
            .map_err(|e| CaptureError::ConfigurationFailed(format!("GetService failed: {}", e)))?;

        // MMCSS registration for real-time priority
        let mut task_index: u32 = 0;
        let task_name: Vec<u16> = "Pro Audio\0".encode_utf16().collect();
        let _mmcss_handle = AvSetMmThreadCharacteristicsW(PCWSTR(task_name.as_ptr()), &mut task_index);

        audio_client
            .Start()
            .map_err(|e| CaptureError::Unknown(format!("IAudioClient::Start failed: {}", e)))?;

        // Capture loop — poll every 10ms
        while running.load(Ordering::SeqCst) {
            thread::sleep(Duration::from_millis(10));

            let mut packet_length = capture_client
                .GetNextPacketSize()
                .map_err(|e| CaptureError::Unknown(format!("GetNextPacketSize failed: {}", e)))?;

            while packet_length > 0 {
                let mut buffer_ptr: *mut u8 = std::ptr::null_mut();
                let mut num_frames: u32 = 0;
                let mut flags: u32 = 0;

                capture_client
                    .GetBuffer(&mut buffer_ptr, &mut num_frames, &mut flags, None, None)
                    .map_err(|e| CaptureError::Unknown(format!("GetBuffer failed: {}", e)))?;

                if num_frames > 0 && !buffer_ptr.is_null() {
                    let total_samples = num_frames as usize * channels as usize;
                    let float_ptr = buffer_ptr as *const f32;
                    let samples = std::slice::from_raw_parts(float_ptr, total_samples);

                    if flags & (AUDCLNT_BUFFERFLAGS_SILENT.0 as u32) != 0 {
                        let silence = vec![0.0f32; total_samples];
                        callback(&silence, sample_rate, channels);
                    } else {
                        callback(samples, sample_rate, channels);
                    }
                }

                capture_client
                    .ReleaseBuffer(num_frames)
                    .map_err(|e| CaptureError::Unknown(format!("ReleaseBuffer failed: {}", e)))?;

                packet_length = capture_client
                    .GetNextPacketSize()
                    .map_err(|e| CaptureError::Unknown(format!("GetNextPacketSize failed: {}", e)))?;
            }
        }

        let _ = audio_client.Stop();
        CoTaskMemFree(Some(mix_format_ptr as *const _ as *const _));
    }

    Ok(())
}

struct CoUninitializeGuard;

impl Drop for CoUninitializeGuard {
    fn drop(&mut self) {
        unsafe {
            CoUninitialize();
        }
    }
}
