# AudioCaptureKit

Cross-platform audio capture library — microphone + system audio mixed into a single stereo recording with AES-256-GCM encryption.

## Platform Support

| Platform | Language | Audio API | Directory |
|----------|----------|-----------|-----------|
| macOS 14+ | Swift 6 | Core Audio Taps + AVFoundation | `macOS/` |
| Windows 10+ | Rust 1.75+ | WASAPI | `windows/` |

## Shared Architecture

Both platforms follow the same **Capture → Processing → Storage** pipeline:

```
┌─────────────────┐     ┌──────────────┐     ┌──────────────────┐
│  Mic Capture     │────▶│              │     │                  │
│  (mono)          │     │  StereoMixer │────▶│  EncryptedFile   │
│                  │     │              │     │  Writer (.wav)   │
│  System Capture  │────▶│              │     │                  │
│  (stereo)        │     └──────────────┘     └──────────────────┘
└─────────────────┘
```

**Stereo mixing** is identical on both platforms: Left = mic + system L, Right = mic + system R. Mic audio is mono, mixed into center of the stereo field. System audio preserves its natural stereo image.

**Encryption**: Both platforms use AES-256-GCM to stream-encrypt audio chunks as they're captured — no plaintext on disk.

## macOS

### Requirements

- macOS 14.0+ (system audio capture requires macOS 14.2+)
- Swift 6.0+
- Entitlement: `com.apple.security.device.audio-input`
- TCC permission: "Screen & System Audio Recording" (for system audio)

### Installation (Swift Package Manager)

```swift
dependencies: [
    .package(path: "../AudioCaptureKit")  // local
    // or
    // .package(url: "https://github.com/yourorg/AudioCaptureKit.git", from: "1.0.0")
]
```

### Quick Start

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

let result = try await session.stopCapture()
print("Recorded \(result.duration)s to \(result.fileURL)")
```

### Testing

```bash
swift test
```

See `macOS/` for source code and `Examples/macOS/` for the sample app.

## Windows

### Requirements

- Windows 10+
- Rust 1.75+

### Building

```bash
cd windows
cargo build --release
```

### Crate Structure

| Crate | Purpose |
|-------|---------|
| `audio-capture-core` | Platform-agnostic models, traits, stereo mixer, encrypted writer |
| `audio-capture-windows` | WASAPI mic capture, WASAPI loopback (system audio), device enumeration |

### Quick Start

```rust
use audio_capture_core::session::CompositeSession;
use audio_capture_core::models::CaptureConfig;
use audio_capture_windows::{WasapiMic, WasapiLoopback};

let config = CaptureConfig::new(48000, 16, 2);
let session = CompositeSession::new(config);

session.start()?;
// ...
let result = session.stop()?;
```

See `windows/` for source code.

### Sample App (Tauri v2)

A desktop GUI at `Examples/windows/SampleApp/` built with Tauri v2 (Rust backend + React frontend). Records mic + system audio, shows real-time level meters, lists recordings, and supports device selection and encryption toggle.

**Prerequisites:** Node.js 18+, Rust 1.77+, Windows 10 SDK

```bash
cd Examples/windows/SampleApp
npm install
npm run tauri dev      # Dev mode with hot reload
npm run tauri build    # Produces .exe + MSI installer in src-tauri/target/release/bundle/
```

## License

MIT
