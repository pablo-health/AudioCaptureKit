//! Windows audio device enumeration via the MMDevice API.
//!
//! Wraps `IMMDeviceEnumerator` to list capture (microphone) and render
//! (speaker/headphone) endpoints with friendly names, transport types,
//! and Bluetooth HFP detection.

use windows::core::*;
use windows::Win32::Devices::FunctionDiscovery::*;
use windows::Win32::Media::Audio::*;
use windows::Win32::System::Com::StructuredStorage::PropVariantClear;
use windows::Win32::System::Com::*;
use windows::Win32::System::Variant::*;

use audio_capture_core::models::audio_models::{AudioSource, AudioTrackType, AudioTransportType};
use audio_capture_core::models::error::CaptureError;

/// Audio device enumerator using the Windows MMDevice API.
pub struct DeviceEnumerator {
    enumerator: IMMDeviceEnumerator,
}

impl DeviceEnumerator {
    /// Create a new device enumerator.
    ///
    /// Requires COM to be initialized on the calling thread.
    pub fn new() -> Result<Self, CaptureError> {
        unsafe {
            let enumerator: IMMDeviceEnumerator =
                CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
                    .map_err(|e| CaptureError::Unknown(format!("failed to create enumerator: {}", e)))?;
            Ok(Self { enumerator })
        }
    }

    /// List active capture (microphone) devices.
    pub fn list_capture_devices(&self) -> Result<Vec<AudioSource>, CaptureError> {
        self.list_devices(eCapture, AudioTrackType::Mic)
    }

    /// List active render (output) devices.
    pub fn list_render_devices(&self) -> Result<Vec<AudioSource>, CaptureError> {
        self.list_devices(eRender, AudioTrackType::System)
    }

    /// Get the default capture device ID.
    pub fn default_capture_device_id(&self) -> Result<String, CaptureError> {
        unsafe {
            let device = self
                .enumerator
                .GetDefaultAudioEndpoint(eCapture, eConsole)
                .map_err(|_| CaptureError::DeviceNotAvailable)?;

            let id = device
                .GetId()
                .map_err(|e| CaptureError::Unknown(format!("GetId failed: {}", e)))?;

            Ok(id.to_string().unwrap_or_default())
        }
    }

    /// Get the default render device ID.
    pub fn default_render_device_id(&self) -> Result<String, CaptureError> {
        unsafe {
            let device = self
                .enumerator
                .GetDefaultAudioEndpoint(eRender, eConsole)
                .map_err(|_| CaptureError::DeviceNotAvailable)?;

            let id = device
                .GetId()
                .map_err(|e| CaptureError::Unknown(format!("GetId failed: {}", e)))?;

            Ok(id.to_string().unwrap_or_default())
        }
    }

    /// Detect if a device is using Bluetooth HFP (low-quality hands-free profile).
    ///
    /// HFP devices typically:
    /// - Have "BTHENUM" in the enumerator name
    /// - Report EndpointFormFactor::Headset
    /// - Use 16kHz or 8kHz mono
    pub fn is_bluetooth_hfp(device_id: &str) -> bool {
        // A full implementation would query PKEY_Device_EnumeratorName
        // for "BTHENUM" and check PKEY_AudioEndpoint_FormFactor.
        // For now, check the device ID for Bluetooth indicators.
        let id_lower = device_id.to_lowercase();
        id_lower.contains("bthenum") || id_lower.contains("bluetooth")
    }

    fn list_devices(
        &self,
        data_flow: EDataFlow,
        source_type: AudioTrackType,
    ) -> Result<Vec<AudioSource>, CaptureError> {
        unsafe {
            let collection = self
                .enumerator
                .EnumAudioEndpoints(data_flow, DEVICE_STATE_ACTIVE)
                .map_err(|e| CaptureError::Unknown(format!("EnumAudioEndpoints failed: {}", e)))?;

            let count = collection
                .GetCount()
                .map_err(|e| CaptureError::Unknown(format!("GetCount failed: {}", e)))?;

            // Get default device ID for comparison
            let default_id = self
                .enumerator
                .GetDefaultAudioEndpoint(data_flow, eConsole)
                .ok()
                .and_then(|d| d.GetId().ok())
                .and_then(|id| id.to_string().ok());

            let mut devices = Vec::new();

            for i in 0..count {
                let device = match collection.Item(i) {
                    Ok(d) => d,
                    Err(_) => continue,
                };

                let id = match device.GetId() {
                    Ok(id) => id.to_string().unwrap_or_default(),
                    Err(_) => continue,
                };

                let name = Self::get_device_friendly_name(&device).unwrap_or_else(|| format!("Device {}", i));

                let transport = Self::detect_transport_type(&device);
                let is_default = default_id.as_deref() == Some(&id);

                devices.push(AudioSource {
                    id,
                    name,
                    source_type,
                    is_default,
                    transport_type: Some(transport),
                });
            }

            Ok(devices)
        }
    }

    /// Read the PKEY_Device_FriendlyName property from a device.
    fn get_device_friendly_name(device: &IMMDevice) -> Option<String> {
        unsafe {
            let store = device
                .OpenPropertyStore(STGM_READ)
                .ok()?;

            let mut prop_variant = std::mem::zeroed::<PROPVARIANT>();
            store
                .GetValue(&PKEY_Device_FriendlyName, &mut prop_variant)
                .ok()?;

            let name = if prop_variant.Anonymous.Anonymous.vt == VT_LPWSTR {
                let pwsz = prop_variant
                    .Anonymous
                    .Anonymous
                    .Anonymous
                    .pwszVal;
                if !pwsz.is_null() {
                    let len = (0..)
                        .take_while(|&i| *pwsz.offset(i) != 0)
                        .count();
                    Some(String::from_utf16_lossy(std::slice::from_raw_parts(
                        pwsz, len,
                    )))
                } else {
                    None
                }
            } else {
                None
            };

            PropVariantClear(&mut prop_variant).ok();
            name
        }
    }

    /// Detect the transport type of an audio device from its property store.
    fn detect_transport_type(device: &IMMDevice) -> AudioTransportType {
        unsafe {
            let store = match device.OpenPropertyStore(STGM_READ) {
                Ok(s) => s,
                Err(_) => return AudioTransportType::Unknown,
            };

            // Check PKEY_Device_EnumeratorName for Bluetooth
            let mut prop = std::mem::zeroed::<PROPVARIANT>();
            if store
                .GetValue(&PKEY_Device_EnumeratorName, &mut prop)
                .is_ok()
            {
                if prop.Anonymous.Anonymous.vt == VT_LPWSTR {
                    let pwsz = prop.Anonymous.Anonymous.Anonymous.pwszVal;
                    if !pwsz.is_null() {
                        let len = (0..)
                            .take_while(|&i| *pwsz.offset(i) != 0)
                            .count();
                        let name = String::from_utf16_lossy(std::slice::from_raw_parts(pwsz, len));
                        PropVariantClear(&mut prop).ok();

                        if name.contains("BTHENUM") {
                            return AudioTransportType::Bluetooth;
                        }
                        if name.contains("BTHLEENUM") {
                            return AudioTransportType::BluetoothLE;
                        }
                        if name.contains("USB") {
                            return AudioTransportType::Usb;
                        }
                    }
                }
                PropVariantClear(&mut prop).ok();
            }

            AudioTransportType::BuiltIn
        }
    }
}
