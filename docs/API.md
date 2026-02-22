# API Reference

AudioCaptureKit provides a symmetric API across macOS (Swift) and Windows (Rust). Both platforms share the same concepts: a session manages capture, providers supply audio, and an encrypted writer handles storage.

## Quick Start

### macOS (Swift)

```swift
import AudioCaptureKit

let config = CaptureConfiguration(
    sampleRate: 48000,
    bitDepth: 16,
    channels: 2,
    outputDirectory: URL.temporaryDirectory
)
let session = CompositeCaptureSession(configuration: config)
session.delegate = myDelegate

try session.configure(config)
try await session.startCapture()
// ...
let result = try await session.stopCapture()
```

### Windows (Rust)

```rust
use audio_capture_core::{CaptureConfiguration, CompositeSession};
use audio_capture_windows::{WasapiMicCapture, WasapiLoopbackCapture};

let config = CaptureConfiguration {
    sample_rate: 48000.0,
    bit_depth: 16,
    channels: 2,
    output_directory: std::env::temp_dir(),
    ..Default::default()
};
let mut session = CompositeSession::new(
    WasapiMicCapture::new(),
    WasapiLoopbackCapture::new(),
);
session.configure(config)?;
session.start_capture()?;
// ...
let result = session.stop_capture()?;
```

---

## Session

The main entry point for audio capture.

### Protocol / Trait

| Swift | Rust |
|-------|------|
| `AudioCaptureSession` protocol | `CaptureSession` trait |

### Implementation

| Swift | Rust |
|-------|------|
| `CompositeCaptureSession` | `CompositeSession<M, S>` |

### Methods

| Operation | Swift | Rust |
|-----------|-------|------|
| Configure | `configure(_ config: CaptureConfiguration) throws` | `configure(&mut self, config: CaptureConfiguration) -> Result<()>` |
| Start | `startCapture() async throws` | `start_capture(&mut self) -> Result<()>` |
| Pause | `pauseCapture() throws` | `pause_capture(&mut self) -> Result<()>` |
| Resume | `resumeCapture() throws` | `resume_capture(&mut self) -> Result<()>` |
| Stop | `stopCapture() async throws -> RecordingResult` | `stop_capture(&mut self) -> Result<RecordingResult>` |
| State | `var state: CaptureState { get }` | `fn state(&self) -> CaptureState` |
| Levels | `var currentLevels: AudioLevels { get }` | `fn current_levels(&self) -> AudioLevels` |
| Sources | `availableAudioSources() async throws -> [AudioSource]` | `fn available_audio_sources(&self) -> Result<Vec<AudioSource>>` |
| Diagnostics | `var diagnostics: CaptureSessionDiagnostics { get }` | `fn diagnostics(&self) -> CaptureSessionDiagnostics` |

---

## Configuration

### CaptureConfiguration

| Property | Swift | Rust | Default |
|----------|-------|------|---------|
| Sample rate | `sampleRate: Double` | `sample_rate: f64` | 48000 |
| Bit depth | `bitDepth: Int` | `bit_depth: u16` | 16 |
| Channels | `channels: Int` | `channels: u16` | 2 |
| Output directory | `outputDirectory: URL` | `output_directory: PathBuf` | required |
| Encryptor | `encryptor: (any CaptureEncryptor)?` | `encryptor: Option<Box<dyn CaptureEncryptor>>` | nil/None |
| Max duration | `maxDuration: TimeInterval?` | `max_duration_secs: Option<f64>` | nil/None |
| Mic device | `micDeviceID: String?` | `mic_device_id: Option<String>` | nil/None (default device) |
| Enable mic | `enableMicCapture: Bool` | `enable_mic_capture: bool` | true |
| Enable system | `enableSystemCapture: Bool` | `enable_system_capture: bool` | true |

Valid bit depths: 16, 24, 32.

---

## State Machine

Both platforms use identical state transitions:

```
idle → configuring → ready → capturing ↔ paused → stopping → completed/failed
```

### CaptureState

| State | Swift | Rust |
|-------|-------|------|
| Idle | `.idle` | `Idle` |
| Configuring | `.configuring` | `Configuring` |
| Ready | `.ready` | `Ready` |
| Capturing | `.capturing(duration: TimeInterval)` | `Capturing { duration_secs: f64 }` |
| Paused | `.paused(duration: TimeInterval)` | `Paused { duration_secs: f64 }` |
| Stopping | `.stopping` | `Stopping` |
| Completed | `.completed(RecordingResult)` | `Completed(Box<RecordingResult>)` |
| Failed | `.failed(CaptureError)` | `Failed(CaptureError)` |

---

## Delegate / Callbacks

### Protocol / Trait

| Swift | Rust |
|-------|------|
| `AudioCaptureDelegate` protocol | `CaptureDelegate` trait |

### Callbacks

| Event | Swift | Rust |
|-------|-------|------|
| State changed | `captureSession(_:didChangeState:)` | `on_state_changed(&self, state: &CaptureState)` |
| Levels updated | `captureSession(_:didUpdateLevels:)` | `on_levels_updated(&self, levels: &AudioLevels)` |
| Error | `captureSession(_:didEncounterError:)` | `on_error(&self, error: &CaptureError)` |
| Finished | `captureSession(_:didFinishCapture:)` | `on_capture_finished(&self, result: &RecordingResult)` |

---

## Capture Providers

Swappable audio sources that feed into the session.

### Protocol / Trait

| Swift | Rust |
|-------|------|
| `AudioCaptureProvider` protocol | `CaptureProvider` trait |

### Built-in Providers

| Source | Swift | Rust |
|--------|-------|------|
| Microphone | `AVFoundationMicCapture` | `WasapiMicCapture` |
| System audio | `CoreAudioTapCapture` | `WasapiLoopbackCapture` |

### Methods

| Operation | Swift | Rust |
|-----------|-------|------|
| Check availability | `var isAvailable: Bool` | `fn is_available(&self) -> bool` |
| Start | `start(bufferCallback:) async throws` | `fn start(&mut self, callback: AudioBufferCallback) -> Result<()>` |
| Stop | `stop() async` | `fn stop(&mut self) -> Result<()>` |

---

## Encryption

All encryption uses AES-256-GCM with streaming chunk-per-nonce. The WAV header is written unencrypted; audio chunks are encrypted with a length prefix.

### Protocol / Trait

| Swift | Rust |
|-------|------|
| `CaptureEncryptor` protocol | `CaptureEncryptor` trait |

### Methods

| Operation | Swift | Rust |
|-----------|-------|------|
| Encrypt | `encrypt(_ data: Data) throws -> Data` | `fn encrypt(&self, data: &[u8]) -> Result<Vec<u8>>` |
| Metadata | `keyMetadata() -> [String: String]` | `fn key_metadata(&self) -> HashMap<String, String>` |
| Algorithm | `var algorithm: String` | `fn algorithm(&self) -> &str` |

### EncryptedFileWriter

| Operation | Swift | Rust |
|-----------|-------|------|
| Create | `init(fileURL:encryptor:)` | `fn new(file_path, encryptor) -> Self` |
| Open | `open(configuration:) throws` | `fn open(&mut self, config) -> Result<()>` |
| Write | `write(_ data: Data) throws` | `fn write(&mut self, data: &[u8]) -> Result<()>` |
| Close | `close(actualSampleRate:channels:bitDepth:) throws -> String` | `fn close(&mut self, actual_sample_rate, channels, bit_depth) -> Result<String>` |
| Bytes written | `var bytesWritten: UInt64` | `fn bytes_written(&self) -> u64` |

---

## Models

### RecordingResult

Returned by `stopCapture()`.

| Property | Swift | Rust |
|----------|-------|------|
| File location | `fileURL: URL` | `file_path: PathBuf` |
| Duration | `duration: TimeInterval` | `duration_secs: f64` |
| Metadata | `metadata: RecordingMetadata` | `metadata: RecordingMetadata` |
| Checksum | `checksum: String` | `checksum: String` |

### AudioLevels

Real-time audio level metering.

| Property | Swift | Rust |
|----------|-------|------|
| Mic level | `micLevel: Float` | `mic_level: f32` |
| System level | `systemLevel: Float` | `system_level: f32` |
| Peak mic | `peakMicLevel: Float` | `peak_mic_level: f32` |
| Peak system | `peakSystemLevel: Float` | `peak_system_level: f32` |

### AudioSource

Represents a discovered audio device.

| Property | Swift | Rust |
|----------|-------|------|
| ID | `id: String` | `id: String` |
| Name | `name: String` | `name: String` |
| Type | `type: AudioTrackType` | `source_type: AudioTrackType` |
| Default | `isDefault: Bool` | `is_default: bool` |
| Transport | `transportType: AudioTransportType?` | `transport_type: Option<AudioTransportType>` |

### CaptureError

| Variant | Swift | Rust |
|---------|-------|------|
| Permission denied | `.permissionDenied` | `PermissionDenied` |
| Device unavailable | `.deviceNotAvailable` | `DeviceNotAvailable` |
| Config failed | `.configurationFailed(String)` | `ConfigurationFailed(String)` |
| Encoding failed | `.encodingFailed(String)` | `EncodingFailed(String)` |
| Encryption failed | `.encryptionFailed(String)` | `EncryptionFailed(String)` |
| Storage error | `.storageError(String)` | `StorageError(String)` |
| Timeout | `.timeout` | `Timeout` |
| Unknown | `.unknown(String)` | `Unknown(String)` |

### Enums

**AudioTrackType**: `mic`, `system`

**AudioChannel**: `left`, `right`, `center`, `stereo`

**AudioTransportType**: `builtIn`, `bluetooth`, `bluetoothLE`, `usb`, `virtual`, `unknown`
