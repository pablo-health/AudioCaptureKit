# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

### macOS (Swift 6 / SPM)
```bash
swift build          # Build the library
swift test           # Run all tests (uses Apple Testing framework, not XCTest)
```

### Windows (C# / .NET 10)
```bash
dotnet build csharp/AudioCapture/AudioCapture.csproj -c Release
dotnet test csharp/AudioCapture.Tests/AudioCapture.Tests.csproj
```

### Linting (macOS)
SwiftLint and SwiftFormat configs live in `macOS/`. Key enforced rules:
- `force_unwrap`, `force_cast`, `force_try` are **errors** — never use these
- `print()` is **forbidden** in non-test code — use `os.log` or `Logger` (HIPAA compliance)
- Line limit: 120 chars (warning), 200 (error)
- Function body: 40 lines (warning), 80 (error)

## Architecture

Cross-platform audio capture library: microphone + system audio mixed into a single encrypted stereo WAV file.

### Pipeline (identical on both platforms)
```
Mic Capture (mono) ──┐
                     ├──▶ StereoMixer ──▶ EncryptedFileWriter ──▶ .wav
System Capture (stereo) ┘
```

**Stereo mixing**: Left = mic + system_L, Right = mic + system_R.

### Platform Implementations

| Concern | macOS (`macOS/Sources/AudioCaptureKit/`) | Windows (`csharp/AudioCapture/`) |
|---------|------------------------------------------|----------------------------------|
| Mic | `AVFoundationMicCapture` (AVFoundation) | `WasapiCaptureSession` (NAudio WasapiCapture) |
| System audio | `CoreAudioTapCapture` (Core Audio Taps, requires macOS 14.2+) | `WasapiCaptureSession` (NAudio WasapiLoopbackCapture) |
| Session | `CompositeCaptureSession` (protocol: `AudioCaptureSession`) | `WasapiCaptureSession` (interface: `ICaptureSession`) |
| Encryption | `EncryptedFileWriter` + `CaptureEncryptor` protocol | `EncryptedWavWriter` + `ICaptureEncryptor` interface |
| Concurrency | Actors, `UnfairLock`, structured concurrency | `lock`, `Task`, async/await |

### Key Design Patterns
- **State machine**: `idle → configuring → ready → capturing ↔ paused → stopping → completed/failed`
- **Encryption**: AES-256-GCM streaming, chunk-per-nonce. Unencrypted WAV header, encrypted audio chunks with length prefix. No plaintext audio on disk.
- **Bluetooth HFP**: Mic capture does a 500ms probe to detect actual sample rate after HFP negotiation before starting real capture.
- **Protocol/interface abstraction**: Capture providers are swappable via `AudioCaptureProvider` (Swift) / `ICaptureSession` (C#).

## Code Style

- UTF-8, LF line endings, 4-space indentation for Swift/C# (see `.editorconfig`)
- Swift: K&R braces, alphabetized imports, no explicit `self`, trailing commas always (see `macOS/.swiftformat`)
- Swift 6 strict concurrency — all types crossing concurrency boundaries must be `Sendable`
