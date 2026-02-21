//! Windows microphone privacy permission check.
//!
//! On Windows 10 1803+, microphone access is controlled by the privacy
//! settings at Settings > Privacy > Microphone. Desktop apps are generally
//! allowed unless the user has disabled the global toggle.
//!
//! Unlike macOS TCC, there's no per-app consent dialog for unpackaged desktop apps.
//! Packaged apps (MSIX/UWP) get an automatic consent prompt.

use windows::core::*;
use windows::Win32::Media::Audio::*;
use windows::Win32::System::Com::*;

use audio_capture_core::models::error::CaptureError;

/// Check if microphone access is available.
///
/// Attempts to open the default capture device. If it fails with
/// `AUDCLNT_E_DEVICE_IN_USE` or access denied, microphone permission
/// is likely disabled in Windows Privacy Settings.
pub fn check_microphone_permission() -> Result<bool, CaptureError> {
    unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED)
            .map_err(|e| CaptureError::Unknown(format!("CoInitializeEx failed: {}", e)))?;

        let result = check_mic_access_inner();

        CoUninitialize();
        result
    }
}

unsafe fn check_mic_access_inner() -> Result<bool, CaptureError> {
    let enumerator: IMMDeviceEnumerator =
        CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
            .map_err(|e| CaptureError::Unknown(format!("failed to create enumerator: {}", e)))?;

    let device = match enumerator.GetDefaultAudioEndpoint(eCapture, eConsole) {
        Ok(d) => d,
        Err(_) => return Ok(false), // No capture device
    };

    // Try to activate IAudioClient — if access is denied, permission is off
    let result: Result<IAudioClient, _> = device.Activate(CLSCTX_ALL, None);

    match result {
        Ok(_) => Ok(true),
        Err(e) => {
            let code = e.code();
            // E_ACCESSDENIED or AUDCLNT_E_DEVICE_IN_USE
            if code.0 == -2147024891i32 || code.0 == -2004287478i32 {
                Ok(false)
            } else {
                // Other error — assume available but report
                log::warn!("Unexpected error checking mic permission: {}", e);
                Ok(true)
            }
        }
    }
}

/// System audio (loopback) capture does not require any permissions on Windows.
pub fn check_system_audio_permission() -> bool {
    // WASAPI loopback is unrestricted — no permissions needed
    true
}
