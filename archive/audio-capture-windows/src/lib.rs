//! # audio-capture-windows
//!
//! Windows WASAPI backend for audio-capture-kit.
//!
//! Provides:
//! - `WasapiMicCapture` — Microphone capture via WASAPI capture endpoint
//! - `WasapiLoopbackCapture` — System audio capture via WASAPI loopback on render endpoint
//! - `DeviceEnumerator` — Audio device enumeration via MMDevice API
//! - `permissions` — Windows microphone privacy check
//!
//! ## Platform Requirements
//! - Windows 10 1703+ (build 15063) for event-driven loopback
//! - Visual Studio Build Tools 2022 + Windows SDK for linking
//!
//! ## Usage
//! ```ignore
//! use audio_capture_windows::{WasapiMicCapture, WasapiLoopbackCapture};
//! use audio_capture_core::CompositeSession;
//!
//! let mic = WasapiMicCapture::default_device().unwrap();
//! let loopback = WasapiLoopbackCapture::default_device().unwrap();
//! let mut session = CompositeSession::new(mic, loopback);
//! ```

#[cfg(target_os = "windows")]
pub mod device_enumerator;
#[cfg(target_os = "windows")]
pub mod permissions;
#[cfg(target_os = "windows")]
pub mod wasapi_loopback;
#[cfg(target_os = "windows")]
pub mod wasapi_mic;

#[cfg(target_os = "windows")]
pub use device_enumerator::DeviceEnumerator;
#[cfg(target_os = "windows")]
pub use wasapi_loopback::WasapiLoopbackCapture;
#[cfg(target_os = "windows")]
pub use wasapi_mic::WasapiMicCapture;
