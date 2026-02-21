//! WASAPI microphone capture provider.
//!
//! Captures audio from a WASAPI capture endpoint (microphone) in shared mode.
//! Delivers Float32 samples via the `AudioBufferCallback`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use parking_lot::Mutex;
use windows::core::*;
use windows::Win32::Media::Audio::*;
use windows::Win32::System::Com::*;
use windows::Win32::System::Threading::*;

use audio_capture_core::models::audio_models::{AudioSource, AudioTrackType, AudioTransportType};
use audio_capture_core::models::error::CaptureError;
use audio_capture_core::traits::capture_provider::{AudioBufferCallback, CaptureProvider};

use crate::device_enumerator::DeviceEnumerator;

/// WASAPI microphone capture.
///
/// Opens a capture endpoint in shared mode and delivers audio buffers
/// on a dedicated high-priority thread registered with MMCSS.
pub struct WasapiMicCapture {
    device_id: Option<String>,
    device_name: String,
    is_default: bool,
    transport_type: Option<AudioTransportType>,
    running: Arc<AtomicBool>,
    capture_handle: Mutex<Option<thread::JoinHandle<()>>>,
}

// SAFETY: All Windows COM objects are used on a single thread (the capture thread).
// The struct fields are either atomics, Mutex-protected, or plain data.
unsafe impl Send for WasapiMicCapture {}
unsafe impl Sync for WasapiMicCapture {}

impl WasapiMicCapture {
    /// Create a capture for the system default microphone.
    pub fn default_device() -> Result<Self, CaptureError> {
        Ok(Self {
            device_id: None,
            device_name: "Default Microphone".into(),
            is_default: true,
            transport_type: None,
            running: Arc::new(AtomicBool::new(false)),
            capture_handle: Mutex::new(None),
        })
    }

    /// Create a capture for a specific microphone by device ID.
    pub fn with_device(id: String, name: String, transport: Option<AudioTransportType>) -> Self {
        Self {
            device_id: Some(id),
            device_name: name,
            is_default: false,
            transport_type: transport,
            running: Arc::new(AtomicBool::new(false)),
            capture_handle: Mutex::new(None),
        }
    }
}

impl CaptureProvider for WasapiMicCapture {
    fn is_available(&self) -> bool {
        // Check if at least one capture device exists
        DeviceEnumerator::new()
            .map(|e| !e.list_capture_devices().unwrap_or_default().is_empty())
            .unwrap_or(false)
    }

    fn start(&mut self, callback: AudioBufferCallback) -> Result<(), CaptureError> {
        if self.running.load(Ordering::SeqCst) {
            return Err(CaptureError::ConfigurationFailed(
                "mic capture already running".into(),
            ));
        }

        self.running.store(true, Ordering::SeqCst);
        let running = Arc::clone(&self.running);
        let device_id = self.device_id.clone();

        let handle = thread::Builder::new()
            .name("wasapi-mic-capture".into())
            .spawn(move || {
                if let Err(e) = mic_capture_loop(running.clone(), device_id, callback) {
                    log::error!("Mic capture error: {}", e);
                }
                running.store(false, Ordering::SeqCst);
            })
            .map_err(|e| CaptureError::Unknown(format!("failed to spawn mic thread: {}", e)))?;

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
            id: self.device_id.clone().unwrap_or_else(|| "default-mic".into()),
            name: self.device_name.clone(),
            source_type: AudioTrackType::Mic,
            is_default: self.is_default,
            transport_type: self.transport_type,
        }
    }
}

/// Main capture loop running on a dedicated thread.
///
/// Sequence:
/// 1. CoInitializeEx (MTA)
/// 2. Get capture device (default or by ID)
/// 3. Activate IAudioClient
/// 4. Initialize in shared mode
/// 5. Get IAudioCaptureClient service
/// 6. Register with MMCSS for real-time priority
/// 7. Start capture, poll for buffers
fn mic_capture_loop(
    running: Arc<AtomicBool>,
    device_id: Option<String>,
    callback: AudioBufferCallback,
) -> Result<(), CaptureError> {
    unsafe {
        // Initialize COM on this thread
        CoInitializeEx(None, COINIT_MULTITHREADED)
            .map_err(|e| CaptureError::Unknown(format!("CoInitializeEx failed: {}", e)))?;

        let _com_guard = CoUninitializeGuard;

        // Get capture device
        let enumerator: IMMDeviceEnumerator =
            CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
                .map_err(|e| CaptureError::DeviceNotAvailable)?;

        let device = if let Some(ref id) = device_id {
            let wide_id: Vec<u16> = id.encode_utf16().chain(std::iter::once(0)).collect();
            let id_pcwstr = PCWSTR(wide_id.as_ptr());
            enumerator
                .GetDevice(id_pcwstr)
                .map_err(|_| CaptureError::DeviceNotAvailable)?
        } else {
            enumerator
                .GetDefaultAudioEndpoint(eCapture, eConsole)
                .map_err(|_| CaptureError::DeviceNotAvailable)?
        };

        // Activate IAudioClient
        let audio_client: IAudioClient = device
            .Activate(CLSCTX_ALL, None)
            .map_err(|e| CaptureError::ConfigurationFailed(format!("Activate failed: {}", e)))?;

        // Get device's mix format
        let mix_format_ptr = audio_client
            .GetMixFormat()
            .map_err(|e| CaptureError::ConfigurationFailed(format!("GetMixFormat failed: {}", e)))?;

        let mix_format = &*mix_format_ptr;
        let sample_rate = mix_format.nSamplesPerSec as f64;
        let channels = mix_format.nChannels;

        // Initialize in shared capture mode
        // Buffer duration: 100ms in 100-nanosecond units
        let buffer_duration = 1_000_000; // 100ms

        audio_client
            .Initialize(
                AUDCLNT_SHAREMODE_SHARED,
                AUDCLNT_STREAMFLAGS_NOPERSIST,
                buffer_duration,
                0,
                mix_format,
                None,
            )
            .map_err(|e| {
                CaptureError::ConfigurationFailed(format!("IAudioClient::Initialize failed: {}", e))
            })?;

        // Get capture client service
        let capture_client: IAudioCaptureClient = audio_client
            .GetService()
            .map_err(|e| {
                CaptureError::ConfigurationFailed(format!("GetService failed: {}", e))
            })?;

        // Register with MMCSS for real-time priority
        let mut task_index: u32 = 0;
        let task_name: Vec<u16> = "Pro Audio\0".encode_utf16().collect();
        let _mmcss_handle = AvSetMmThreadCharacteristicsW(
            PCWSTR(task_name.as_ptr()),
            &mut task_index,
        );

        // Start capture
        audio_client
            .Start()
            .map_err(|e| CaptureError::Unknown(format!("IAudioClient::Start failed: {}", e)))?;

        // Capture loop
        while running.load(Ordering::SeqCst) {
            thread::sleep(Duration::from_millis(10));

            let mut packet_length: u32 = 0;
            capture_client
                .GetNextPacketSize(&mut packet_length)
                .map_err(|e| CaptureError::Unknown(format!("GetNextPacketSize failed: {}", e)))?;

            while packet_length > 0 {
                let mut buffer_ptr: *mut u8 = std::ptr::null_mut();
                let mut num_frames: u32 = 0;
                let mut flags: u32 = 0;

                capture_client
                    .GetBuffer(
                        &mut buffer_ptr,
                        &mut num_frames,
                        &mut flags,
                        None,
                        None,
                    )
                    .map_err(|e| CaptureError::Unknown(format!("GetBuffer failed: {}", e)))?;

                if num_frames > 0 && !buffer_ptr.is_null() {
                    let total_samples = num_frames as usize * channels as usize;

                    // WASAPI delivers Float32 in shared mode
                    let float_ptr = buffer_ptr as *const f32;
                    let samples =
                        std::slice::from_raw_parts(float_ptr, total_samples);

                    // Handle silence flag
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

                capture_client
                    .GetNextPacketSize(&mut packet_length)
                    .map_err(|e| CaptureError::Unknown(format!("GetNextPacketSize failed: {}", e)))?;
            }
        }

        // Stop and clean up
        let _ = audio_client.Stop();
        CoTaskMemFree(Some(mix_format_ptr as *const _ as *const _));
    }

    Ok(())
}

/// RAII guard to call CoUninitialize when dropped.
struct CoUninitializeGuard;

impl Drop for CoUninitializeGuard {
    fn drop(&mut self) {
        unsafe {
            CoUninitialize();
        }
    }
}
