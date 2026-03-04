# Speaker Diarization Support

AudioCaptureKit enables speaker diarization without ML inference by exploiting a structural advantage: **channel identity is known at capture time**. The library exposes this via configurable channel layout and raw per-channel buffer callbacks.

---

## Overview

In a typical telehealth or remote-work session:

| Audio Source | Identity |
|---|---|
| Microphone | Local speaker (always known) |
| System audio | Remote participants (routed through the OS) |

These two sources are captured independently and can be kept separate in the output WAV or exposed to the caller before mixing. No speaker diarization model is needed to distinguish between "who spoke" — the library already knows.

---

## Channel Strategy

Use `MixingStrategy` to control what goes into each WAV channel:

### `blended` (default)

| Channel | Content |
|---|---|
| Left  | mic + system_L |
| Right | mic + system_R |

Legacy behavior. Good for playback and listening. The mic signal is blended into both channels, preserving the stereo image of system audio. Not suitable for independent per-speaker processing.

### `separated`

| Channel | Content |
|---|---|
| Left (Ch 1)  | mic only (mono mic signal) |
| Right (Ch 2) | system audio, mono-folded: (system_L + system_R) / 2 |

Clean channel separation. Left = local speaker, Right = remote. The mono-fold of system audio preserves content from both left and right system channels — no panned audio is discarded. Use this for speaker-attributed transcription, AI note-taking, or compliance recording where speaker identity matters.

### `multichannel` (reserved)

Currently behaves identically to `separated`. Reserved for future 3–4 channel multi-mic configurations.

---

## Diarization Scenarios

### Telehealth (trivial diarization)

One local speaker (mic) and one remote participant (system audio). No diarization model needed:

```swift
let config = CaptureConfiguration(
    mixingStrategy: .separated,
    outputDirectory: recordingsURL
)
```

Process `Ch1 (Left)` independently for the local provider and `Ch2 (Right)` for the remote patient. Speaker identity is structurally guaranteed.

### Couples Counseling (two-speaker diarization on one channel)

Two remote participants on a video call (system audio) with one local therapist (mic). Strategy:

1. Use `mixingStrategy: .separated` to isolate the mic from system audio.
2. Implement `captureSession(_:didProduceChannelBuffers:)` to receive the raw system stereo buffers.
3. Run a 2-speaker diarization model only on `systemSamples` — much cheaper than diarizing the full mix.

### In-Person Session (full diarization required)

Multiple people speaking in the same room captured by a single microphone. Standard diarization applies. Use `didProduceChannelBuffers` to receive the mic buffer in real time and feed it to your diarization pipeline.

---

## `didProduceChannelBuffers` Callback

AudioCaptureKit fires this delegate method on every processing cycle (~100 ms intervals), **before** mixing and file writing. This gives callers access to the highest-quality raw audio for each source.

### Swift

```swift
class MyDelegate: AudioCaptureDelegate {
    func captureSession(
        _ session: any AudioCaptureSession,
        didProduceChannelBuffers buffers: ChannelBuffers
    ) {
        // micSamples: mono Float32 array at session sample rate
        let micSamples = buffers.micSamples

        // systemSamples: interleaved stereo [L0, R0, L1, R1, ...]
        // The library does NOT fold this to mono. If you need mono:
        let systemMono = stride(from: 0, to: buffers.systemSamples.count, by: 2).map {
            (buffers.systemSamples[$0] + buffers.systemSamples[$0 + 1]) / 2
        }

        // Feed into real-time ASR, level meters, etc.
        // Non-blocking: dispatch heavy work to a background queue.
        Task.detached {
            await self.speechEngine.process(mic: micSamples)
        }
    }
}
```

> **Important:** `systemSamples` is full interleaved stereo. If your pipeline requires mono system audio (e.g., for single-channel ASR), average the channels yourself: `(system[2i] + system[2i+1]) / 2`. The library never degrades audio quality on behalf of the caller.

> **Threading:** This callback fires on an unspecified background queue. Implementations must be non-blocking. Dispatch heavy work asynchronously.

### Rust

```rust
session.set_channel_buffer_callback(Arc::new(|buffers: &ChannelBuffers| {
    // mic_samples: mono f32 slice
    // system_samples: interleaved stereo [L0, R0, L1, R1, ...]
    let _mic = &buffers.mic_samples;
    let _system = &buffers.system_samples;
    // Non-blocking: spawn a thread or send to a channel
}));
```

---

## Raw PCM Sidecar Files

Enable `exportRawPCM` to write unencrypted raw PCM files alongside the main WAV for use with external tools (whisper.cpp, Sox, FFmpeg, etc.):

```swift
let config = CaptureConfiguration(
    mixingStrategy: .separated,
    exportRawPCM: true,
    outputDirectory: recordingsURL
)
```

This produces two additional files:

| File | Format | Content |
|---|---|---|
| `{name}_mic.pcm` | Signed 16-bit LE, no header, mono | Microphone channel only |
| `{name}_system.pcm` | Signed 16-bit LE, no header, interleaved stereo | System audio, full stereo |

The PCM sidecar files are **never encrypted**, even when the WAV file is encrypted.

Their paths are available in `RecordingResult.rawPCMFileURLs` (Swift) / `RecordingResult.raw_pcm_file_paths` (Rust):
- Index 0: mic PCM
- Index 1: system PCM

### Using with external tools

```bash
# Transcribe mic with whisper.cpp
ffmpeg -f s16le -ar 48000 -ac 1 -i recording_mic.pcm mic.wav
./whisper -m models/ggml-base.en.bin -f mic.wav

# Transcribe system audio
ffmpeg -f s16le -ar 48000 -ac 2 -i recording_system.pcm system.wav
./whisper -m models/ggml-base.en.bin -f system.wav
```

---

## `MixingStrategy` Reference

| Strategy | WAV Ch1 (Left) | WAV Ch2 (Right) | Use case |
|---|---|---|---|
| `blended` | mic + system_L | mic + system_R | Playback, recording review |
| `separated` | mic only (mono) | system mono-fold (L+R)/2 | Diarization, AI transcription |
| `multichannel` | _(same as separated)_ | _(same as separated)_ | Reserved |

### Swift

```swift
public enum MixingStrategy: Sendable, Codable {
    case blended
    case separated
    case multichannel
}
```

### Rust

```rust
pub enum MixingStrategy {
    Blended,    // default
    Separated,
    Multichannel,
}
```

---

## `ChannelLayout` in `RecordingMetadata`

`RecordingMetadata` includes a `channelLayout` field so decoders never need to guess the WAV layout:

| `MixingStrategy` | `ChannelLayout` |
|---|---|
| `blended` | `blended` |
| `separated` | `separatedStereo` |
| `multichannel` | `separatedStereo` |

Old recordings without a `channelLayout` field deserialize as `blended` for backward compatibility.

---

## AudioTrack Labels

When using `separated` strategy, `RecordingMetadata.tracks` contains labeled tracks:

```json
[
  { "type": "mic",    "channel": "L", "label": "Mic (Local)" },
  { "type": "system", "channel": "R", "label": "System (Remote, mono-fold)" }
]
```

---

## Future: Multi-Mic (3–4 Channel)

The mixer reserves `multichannel` strategy and channel counts 3–4 in `CaptureConfiguration` for future multi-mic support. The current implementation produces 2-channel output regardless of channel count. Support for a third dedicated system-stereo channel is planned.

When implemented, a 3-channel layout will provide:

| Channel | Content |
|---|---|
| Ch 1 (Left)  | mic only |
| Ch 2 (Right) | system_L |
| Ch 3 | system_R |

This will require WAV format changes and is tracked separately.
