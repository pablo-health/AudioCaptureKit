# iOS Audio Capture — Design Document

**Status:** Proposed
**Last updated:** 2026-03-05

## Background

AudioCaptureKit currently targets macOS only, using Core Audio Taps for system audio and AVFoundation for microphone. This document defines the architecture for extending the library to iOS, covering in-person meeting recording and video call recording (Zoom, Teams, FaceTime, etc.).

## iOS vs macOS Capabilities

| Capability | macOS | iOS |
|---|---|---|
| Microphone capture | AVFoundation | AVFoundation (AVAudioSession) |
| System audio capture | Core Audio Taps (macOS 14.2+) | **Not available** |
| Video call audio | Via system tap | Via Broadcast Upload Extension |
| Cellular call recording | N/A | **Not possible (Apple sandbox)** |
| VoIP call recording (your app) | Full | Full via AVAudioSession + CallKit |

**Key constraint:** iOS has no equivalent to `CATapDescription` / `AudioHardwareCreateProcessTap`. Third-party apps cannot capture another app's audio — with one exception: the Broadcast Upload Extension receives `.audioApp` samples for the active foreground app.

## Use Cases

### UC-1: In-Person Meeting Recording
User opens the app, selects a patient, taps Record. The mic captures room audio. No system audio track.

**Pipeline:**
```
Mic (AVAudioSession) → StereoMixer (mono passthrough) → EncryptedFileWriter → .wav
```

### UC-2: Video Call Recording (Zoom, Teams, FaceTime, WhatsApp, etc.)
User selects a patient, taps "Start Recording", confirms the broadcast prompt, then joins/is in a video call. The Broadcast Upload Extension captures both audio legs.

**Pipeline:**
```
.audioMic  (CMSampleBuffer) ──┐
                               ├── BroadcastCaptureProvider → StereoMixer → EncryptedFileWriter → .wav
.audioApp  (CMSampleBuffer) ──┘
```
- Left channel = mic (your voice)
- Right channel = app audio (far end — what comes through the speaker)

**User flow:**
1. User selects patient in app
2. App stores patient context in shared App Group (`group.com.pablo.audiocapturekit`)
3. App presents `RPSystemBroadcastPickerView` — a native in-app button
4. User taps "Start Broadcast" (one tap, inside your app)
5. Broadcast Extension launches, reads patient context from App Group
6. App deep-links to meeting: `UIApplication.shared.open(URL("zoomus://..."))`
7. Recording runs in background while Zoom is foreground
8. User taps Stop in status bar (or app stops programmatically via `RPBroadcastActivityViewController`)
9. Main app finalizes recording, associates with patient

### UC-3: Cellular Phone Calls
**Not feasible.** Apple's sandbox prevents any third-party extension from accessing cellular call audio. iOS 18.1 added native call recording but exposed no API. This use case is out of scope.

### UC-4: VoIP App (Future)
If pablo-health ships its own calling app using CallKit, the app owns the `AVAudioSession` and can record both legs natively. Out of scope for AudioCaptureKit library itself.

## Architecture

### New Types (iOS only)

**`IOSMicCaptureSession`** — conforms to `AudioCaptureSession`
- Wraps `AVFoundationMicCapture` (reused as-is)
- Handles `AVAudioSession` lifecycle: `.record` category, interruption notifications (phone calls, Siri)
- `enableSystemCapture` config flag is silently ignored on iOS
- Platform: iOS 16+

**`BroadcastCaptureProvider`** — conforms to `AudioCaptureProvider`
- Lives in a separate App Extension target (not in the main app)
- Subclass of `RPBroadcastSampleHandler`
- Converts `CMSampleBuffer` (`.audioMic`, `.audioApp`) → `AVAudioPCMBuffer`
- Writes to a shared `AudioBufferManager` via App Group file or IPC
- Platform: iOS 16+

### Reused (unchanged)
- `StereoMixer` — already platform-agnostic
- `EncryptedFileWriter` — already platform-agnostic (actor)
- `AudioBufferManager` — already platform-agnostic
- `CaptureConfiguration` — add iOS-specific validation
- `RecordingResult`, `RecordingMetadata`, `AudioLevels` — unchanged

### Package Structure
```
Package.swift — add .iOS(.v16) to platforms
macOS/Sources/AudioCaptureKit/   — unchanged
iOS/Sources/AudioCaptureKit/
  Capture/
    IOSMicCaptureSession.swift
    BroadcastCaptureProvider.swift
  Shared/                        — symlinks to cross-platform processing code
```

### App Group IPC
The Broadcast Extension runs in a separate process. Communication with the main app uses a shared App Group container:
- `UserDefaults(suiteName: "group.com.pablo.audiocapturekit")` for patient context
- Shared file path for audio buffer hand-off on extension stop

## Entitlements Required
- `com.apple.security.application-groups` — for App Group shared container
- `NSMicrophoneUsageDescription` — mic access
- No special entitlements needed for Broadcast Upload Extension (ReplayKit is public API)

## What This Does NOT Support
- Cellular call recording (Apple sandbox; impossible)
- System-wide audio capture (no iOS equivalent to Core Audio Taps)
- Silent/background recording without user initiating broadcast
- Zoom raw PCM without screen recording (would require backend bot infrastructure)

## Open Questions
- Should `BroadcastCaptureProvider` be a separate Swift package target, or bundled as an extension template?
- Encryption key management across app ↔ extension boundary (Keychain with shared access group)
- Max recording duration in extension context (iOS may terminate long-running extensions)
