# Android Audio Capture — Design Document

**Status:** Proposed
**Last updated:** 2026-03-05

## Background

AudioCaptureKit currently targets macOS (Swift/AVFoundation + Core Audio Taps) and Windows (Rust/WASAPI). This document defines the architecture for extending the library to Android, where — unlike iOS — a real system audio capture API exists: `AudioPlaybackCapture` via `MediaProjection` (Android 10 / API 29+). This gives Android feature parity with macOS and Windows for the full mic + system audio pipeline.

## Android vs macOS Capabilities

| Capability | macOS | Android |
|---|---|---|
| Microphone capture | AVFoundation | AudioRecord (API 1+) ✓ |
| System audio capture | Core Audio Taps (macOS 14.2+) | AudioPlaybackCapture + MediaProjection (API 29+) ✓ |
| Cellular call audio | N/A | Not possible — VOICE_COMMUNICATION excluded from AudioPlaybackCapture |
| Concurrency model | Actors, structured concurrency | Kotlin coroutines |

**Key advantage over iOS:** Android's `AudioPlaybackCapture` API allows third-party apps to capture system audio (with user consent via `MediaProjection`), enabling the same full stereo pipeline as macOS and Windows. Apps can opt out via `android:allowAudioPlaybackCapture="false"` in their manifest.

## Use Cases

### UC-1: In-Person Meeting Recording
User opens the app, selects a patient, taps Record. The mic captures room audio. No system audio needed.

**Pipeline:**
```
Mic (AudioRecord) → StereoMixer (mono passthrough) → EncryptedFileWriter → .wav
```

**Minimum API:** 23 (Android 6.0 — runtime permissions required for RECORD_AUDIO)

### UC-2: Screen/App Audio Recording
User selects a patient, taps "Start Recording", grants MediaProjection consent, then joins a video call. Both mic and system audio are captured and mixed.

**Pipeline:**
```
Mic (AudioRecord) ──────────────────────────────────────┐
                                                         ├──▶ StereoMixer ──▶ EncryptedFileWriter ──▶ .wav
System audio (AudioRecord + AudioPlaybackCaptureConfig) ─┘
```

- Left channel = mic (your voice) + system_L
- Right channel = mic (your voice) + system_R

**User flow:**
1. User selects patient in app
2. App requests MediaProjection via `MediaProjectionManager.createScreenCaptureIntent()`
3. User approves consent dialog (one tap)
4. App stores projection token, starts foreground service
5. `AndroidPlaybackCaptureProvider` creates `AudioRecord` with `AudioPlaybackCaptureConfiguration`
6. `AndroidMicCaptureProvider` starts mic `AudioRecord` in parallel
7. Both PCM streams feed into `StereoMixer`
8. User taps Stop; foreground service tears down both capture providers

**Minimum API:** 29 (Android 10)

### UC-3: Cellular Phone Calls
**Not feasible.** Android excludes `USAGE_VOICE_COMMUNICATION` from `AudioPlaybackCapture` by design. No public API grants access to cellular call audio for third-party apps.

## Architecture — New Types

**`AndroidMicCaptureProvider`** — conforms to `CaptureProvider`-equivalent interface
- Wraps `android.media.AudioRecord` with `AudioFormat.CHANNEL_IN_MONO`, `AudioFormat.ENCODING_PCM_16BIT`
- Runs on a dedicated coroutine reading PCM buffers in a loop
- Handles `RECORD_AUDIO` permission check before initialization
- Reports actual sample rate after construction (device-dependent)
- Platform: API 23+

**`AndroidPlaybackCaptureProvider`** — conforms to `CaptureProvider`-equivalent interface
- Creates `AudioRecord` via `AudioRecord.Builder` with `AudioPlaybackCaptureConfiguration`
- Requires a valid `MediaProjection` token passed in at construction
- Captures stereo PCM (system default sample rate, typically 44100 or 48000 Hz)
- Releases `MediaProjection` on stop
- Platform: API 29+

**`AndroidCaptureSession`** — state machine + foreground service lifecycle
- State machine: `idle → configuring → ready → capturing ↔ paused → stopping → completed/failed`
- Runs as a bound `ForegroundService` with `FOREGROUND_SERVICE_TYPE_MICROPHONE` (API 29+) or `FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION` (API 34+)
- Manages both providers via coroutine scopes
- Exposes `Flow<AudioLevels>` and `Flow<CaptureState>` for UI observation
- On pause: stops reading PCM buffers but keeps `AudioRecord` instances allocated
- On stop: finalizes `EncryptedFileWriter`, releases all resources

## Reused Components

| Component | Reuse strategy |
|---|---|
| `StereoMixer` | Port math to Kotlin (identical algorithm: L = mic + sys_L, R = mic + sys_R) |
| `EncryptedFileWriter` | Re-implement in Kotlin using Conscrypt or `javax.crypto` AES-256-GCM |
| WAV format | Port WAV header writer from Rust (`audio-capture-core`) to Kotlin |
| State machine | Replicate `idle → capturing → completed/failed` transitions in `AndroidCaptureSession` |

## Language & Build

- **Language:** Kotlin (coroutines for async, `Flow` for streaming state)
- **Directory:** `android/` at repo root
- **Build system:** Gradle (Kotlin DSL), `android/build.gradle.kts`
- **Min SDK:** 23 for mic-only; 29 for full pipeline
- **Target SDK:** latest stable (API 35)

## Permissions Required

```xml
<!-- AndroidManifest.xml -->
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
<!-- API 34+ requires explicit media projection foreground service type -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" />
```

`MediaProjection` does not require a manifest permission — it requires a runtime user consent dialog via `MediaProjectionManager`.

## Known Limitations

- **App opt-out:** Apps with `android:allowAudioPlaybackCapture="false"` in their manifest are excluded from system capture. This includes some banking and DRM-protected media apps.
- **OEM variations:** Some OEM audio stacks report different sample rates or channel configurations than AOSP. `AndroidMicCaptureProvider` must query the actual sample rate post-construction.
- **No telephony audio:** `USAGE_VOICE_COMMUNICATION` (phone calls, VoIP) is excluded from `AudioPlaybackCapture` by the OS.
- **Foreground service requirement:** Android 14 (API 34) enforces explicit `foregroundServiceType` for MediaProjection services and requires the user to re-grant consent if the app is killed.

## Open Questions

- **Min API strategy:** Ship mic-only path at API 23 and system audio path at API 29? Or require API 29 for the library and let the host app handle the fallback UI?
- **Encryption provider:** `javax.crypto` (built-in, no extra dependency) vs. Conscrypt (Google's BoringSSL-based provider, stronger AES-GCM guarantees) vs. Signal's `AES-GCM-Provider`?
- **Sample app:** Standalone Android app in `android/sample/`, or a Compose Multiplatform example shared with a future KMP integration?
