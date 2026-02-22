# AudioCaptureKit

A Swift library for dual-source audio capture on macOS — microphone + system audio mixed into a single stereo recording with optional AES-256-GCM encryption.

## Features

- **Dual-source capture**: Record microphone and system audio simultaneously
- **Stereo mixing**: Mic centered in stereo field, system audio preserving its natural stereo image (L = mic + system L, R = mic + system R)
- **AES-256-GCM encryption**: Stream-encrypt audio chunks as they're captured — no plaintext on disk
- **Real-time metering**: Live audio levels for both mic and system sources
- **Bluetooth HFP handling**: Detects and warns when Bluetooth headset forces low-quality HFP mode
- **No system extensions**: Uses Core Audio Taps (macOS 14.2+) — just entitlements and TCC permission
- **Swift 6 strict concurrency**: Thread-safe with `@unchecked Sendable` + `UnfairLock` for real-time audio callbacks

## Requirements

- macOS 14.0+ (system audio capture requires macOS 14.2+)
- Swift 6.0+
- Entitlement: `com.apple.security.device.audio-input`
- TCC permission: "Screen & System Audio Recording" (for system audio)

## Installation

### Swift Package Manager

Add AudioCaptureKit as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(path: "../AudioCaptureKit")  // local
    // or
    // .package(url: "https://github.com/yourorg/AudioCaptureKit.git", from: "1.0.0")
]
```

Then add it to your target:

```swift
.target(
    name: "YourApp",
    dependencies: ["AudioCaptureKit"]
)
```

## Quick Start

```swift
import AudioCaptureKit

// 1. Create a session with configuration
let config = CaptureConfiguration(
    sampleRate: 48000,
    bitDepth: 16,
    channels: 2,
    outputDirectory: URL.temporaryDirectory
)
let session = CompositeCaptureSession(configuration: config)

// 2. Set up a delegate for events
session.delegate = myDelegate  // implements AudioCaptureDelegate

// 3. Configure and start
try session.configure(config)
try await session.startCapture()

// 4. Stop and get the result
let result = try await session.stopCapture()
print("Recorded \(result.duration)s to \(result.fileURL)")
```

### With Encryption

```swift
let config = CaptureConfiguration(
    sampleRate: 48000,
    bitDepth: 16,
    channels: 2,
    encryptor: myEncryptor,  // implements CaptureEncryptor
    outputDirectory: URL.temporaryDirectory
)
```

## Architecture

AudioCaptureKit follows a **Capture → Processing → Storage** pipeline:

```
┌─────────────────────┐     ┌──────────────┐     ┌────────────────────┐
│  AVFoundationMic    │────▶│              │     │                    │
│  Capture (mono)     │     │  StereoMixer │────▶│  EncryptedFile     │
│                     │     │              │     │  Writer (.wav)     │
│  CoreAudioTap       │────▶│              │     │                    │
│  Capture (stereo)   │     └──────────────┘     └────────────────────┘
└─────────────────────┘
```

- **Capture layer**: `AVFoundationMicCapture` (mic via AVCaptureSession) and `CoreAudioTapCapture` (system audio via Core Audio process taps + aggregate device)
- **Processing layer**: `StereoMixer` (sample rate conversion + stereo mixing) and `AudioFormatConverter` (format conversion + WAV headers)
- **Storage layer**: `EncryptedFileWriter` (streaming WAV output with optional per-chunk AES-256-GCM encryption)
- **Coordination**: `CompositeCaptureSession` orchestrates the full pipeline, implements `AudioCaptureSession` protocol

## Key Protocols

| Protocol | Purpose |
|----------|---------|
| `AudioCaptureSession` | Full capture lifecycle (configure, start, pause, resume, stop) |
| `AudioCaptureDelegate` | Receive state changes, audio levels, errors, and recording results |
| `AudioCaptureProvider` | Internal: individual audio source (mic or system) |
| `CaptureEncryptor` | Plug in your own encryption (AES-256-GCM, etc.) |

## Known Gotchas

- **Bluetooth HFP**: When the same Bluetooth device is both mic and output, macOS forces HFP mode (~16kHz mono). AudioCaptureKit detects this and adjusts the output sample rate accordingly.
- **TCC permissions**: System audio capture requires "Screen & System Audio Recording" permission. The app must have a bundle ID, be code-signed, and be launched from `/Applications/`.
- **Aggregate device pattern**: Core Audio process taps cannot be read directly. AudioCaptureKit creates an aggregate device wrapping the tap + output device, then attaches an IO proc.
- **Device changes during recording**: Aggregate device creation fires device change notifications. AudioCaptureKit only stops recording if the selected mic actually disappeared.

## Testing

```bash
swift test
```

## License

MIT
