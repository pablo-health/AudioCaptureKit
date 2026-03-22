# API Reference

AudioCaptureKit provides a symmetric API across macOS (Swift) and Windows (C#). Both platforms share the same concepts: a session manages capture, providers supply audio, and an encrypted writer handles storage.

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

### Windows (C#)

```csharp
using AudioCapture.Capture;
using AudioCapture.Models;

var config = new CaptureConfiguration
{
    SampleRate = 48000,
    BitDepth = 16,
    Channels = 2,
    OutputDirectory = Path.GetTempPath()
};
var session = new WasapiCaptureSession();
session.Configure(config);

var result = await session.StartCaptureAsync();
// ...
var recording = await session.StopCaptureAsync();
```

---

## Session

The main entry point for audio capture.

### Protocol / Interface

| Swift | C# |
|-------|-----|
| `AudioCaptureSession` protocol | `ICaptureSession` interface |

### Implementation

| Swift | C# |
|-------|-----|
| `CompositeCaptureSession` | `WasapiCaptureSession` |

### Methods

| Operation | Swift | C# |
|-----------|-------|-----|
| Configure | `configure(_ config: CaptureConfiguration) throws` | `Configure(CaptureConfiguration configuration)` |
| Start | `startCapture() async throws` | `StartCaptureAsync() -> Task<RecordingResult>` |
| Pause | `pauseCapture() throws` | `PauseCapture()` |
| Resume | `resumeCapture() throws` | `ResumeCapture()` |
| Stop | `stopCapture() async throws -> RecordingResult` | `StopCaptureAsync() -> Task<RecordingResult>` |
| State | `var state: CaptureState { get }` | `CaptureState State { get; }` |
| Levels | `var currentLevels: AudioLevels { get }` | `AudioLevels CurrentLevels { get; }` |
| Sources | `availableAudioSources() async throws -> [AudioSource]` | `GetAvailableAudioSourcesAsync() -> Task<AudioSource[]>` |
| Diagnostics | `var diagnostics: CaptureSessionDiagnostics { get }` | — |

---

## Configuration

### CaptureConfiguration

| Property | Swift | C# | Default |
|----------|-------|-----|---------|
| Sample rate | `sampleRate: Double` | `SampleRate: double` | 48000 |
| Bit depth | `bitDepth: Int` | `BitDepth: int` | 16 |
| Channels | `channels: Int` | `Channels: int` | 2 |
| Output directory | `outputDirectory: URL` | `OutputDirectory: string` | required |
| Encryptor | `encryptor: (any CaptureEncryptor)?` | `Encryptor: ICaptureEncryptor?` | nil/null |
| Max duration | `maxDuration: TimeInterval?` | `MaxDuration: TimeSpan?` | nil/null |
| Mic device | `micDeviceID: String?` | `MicDeviceId: string?` | nil/null (default device) |
| Enable mic | `enableMicCapture: Bool` | `EnableMicCapture: bool` | true |
| Enable system | `enableSystemCapture: Bool` | `EnableSystemCapture: bool` | true |

Valid bit depths: 16, 24, 32.

Valid channel counts: 1–4. Channels 3–4 are reserved for future multi-mic support; the mixer currently produces 2-channel output regardless.

| Property | Swift | C# | Default |
|----------|-------|-----|---------|
| Mixing strategy | `mixingStrategy: MixingStrategy` | `MixingStrategy: MixingStrategy` | `.blended` / `Blended` |
| Export raw PCM | `exportRawPCM: Bool` | `ExportRawPcm: bool` | false |

See [DIARIZATION.md](DIARIZATION.md) for full mixing strategy documentation.

---

## State Machine

Both platforms use identical state transitions:

```
idle → configuring → ready → capturing ↔ paused → stopping → completed/failed
```

### CaptureState

| State | Swift | C# |
|-------|-------|-----|
| Idle | `.idle` | `Idle` |
| Configuring | `.configuring` | `Configuring` |
| Ready | `.ready` | `Ready` |
| Capturing | `.capturing(duration: TimeInterval)` | `Capturing` |
| Paused | `.paused(duration: TimeInterval)` | `Paused` |
| Stopping | `.stopping` | `Stopping` |
| Completed | `.completed(RecordingResult)` | `Completed` |
| Failed | `.failed(CaptureError)` | `Failed` |

---

## Delegate / Callbacks

### Protocol / Interface

| Swift | C# |
|-------|-----|
| `AudioCaptureDelegate` protocol | `ICaptureDelegate` interface |

### Callbacks

| Event | Swift | C# |
|-------|-------|-----|
| State changed | `captureSession(_:didChangeState:)` | `OnStateChanged(CaptureState state)` |
| Levels updated | `captureSession(_:didUpdateLevels:)` | `OnLevelsUpdated(AudioLevels levels)` |
| Error | `captureSession(_:didEncounterError:)` | `OnError(CaptureException error)` |
| Finished | `captureSession(_:didFinishCapture:)` | `OnCaptureFinished(RecordingResult result)` |
| Channel buffers | `captureSession(_:didProduceChannelBuffers:)` | — |

The `didProduceChannelBuffers` callback (Swift) fires on every processing cycle (~100 ms) with raw per-channel audio before mixing. Has a default no-op implementation so existing delegates compile unchanged. See [DIARIZATION.md](DIARIZATION.md) for usage examples.

---

## Capture Providers

Swappable audio sources that feed into the session.

### Protocol / Interface

| Swift | C# |
|-------|-----|
| `AudioCaptureProvider` protocol | `ICaptureSession` (unified) |

### Built-in Providers

| Source | Swift | C# |
|--------|-------|-----|
| Microphone | `AVFoundationMicCapture` | `WasapiCaptureSession` (NAudio WasapiCapture) |
| System audio | `CoreAudioTapCapture` | `WasapiCaptureSession` (NAudio WasapiLoopbackCapture) |

---

## Encryption

All encryption uses AES-256-GCM with streaming chunk-per-nonce. The WAV header is written unencrypted; audio chunks are encrypted with a length prefix.

### Protocol / Interface

| Swift | C# |
|-------|-----|
| `CaptureEncryptor` protocol | `ICaptureEncryptor` interface |

### Methods

| Operation | Swift | C# |
|-----------|-------|-----|
| Encrypt | `encrypt(_ data: Data) throws -> Data` | `Encrypt(byte[] data) -> byte[]` |
| Metadata | `keyMetadata() -> [String: String]` | `KeyMetadata -> Dictionary<string, string>` |
| Algorithm | `var algorithm: String` | `Algorithm -> string` |

### EncryptedFileWriter / EncryptedWavWriter

| Operation | Swift | C# |
|-----------|-------|-----|
| Create | `init(fileURL:encryptor:)` | `new EncryptedWavWriter(filePath, encryptor)` |
| Open | `open(configuration:) throws` | `Open(configuration)` |
| Write | `write(_ data: Data) throws` | `Write(byte[] data)` |
| Close | `close(actualSampleRate:channels:bitDepth:) throws -> String` | `Close(sampleRate, channels, bitDepth) -> string` |
| Bytes written | `var bytesWritten: UInt64` | `BytesWritten -> long` |

---

## Models

### RecordingResult

Returned by `stopCapture()`.

| Property | Swift | C# |
|----------|-------|-----|
| File location | `fileURL: URL` | `FilePath: string` |
| Duration | `duration: TimeInterval` | `Duration: TimeSpan` |
| Metadata | `metadata: RecordingMetadata` | `Metadata: RecordingMetadata` |
| Checksum | `checksum: String` | `Checksum: string` |
| Raw PCM files | `rawPCMFileURLs: [URL]` | `RawPcmFilePaths: string[]` |

`rawPCMFileURLs` / `RawPcmFilePaths` is empty unless `exportRawPCM` was enabled. When populated: index 0 = mic (mono), index 1 = system (stereo interleaved).

### ChannelBuffers

Raw per-channel audio from one processing cycle. Delivered via the channel buffers callback before mixing.

| Property | Swift |
|----------|-------|
| Mic audio | `micSamples: [Float]` |
| System audio | `systemSamples: [Float]` |
| Sample rate | `sampleRate: Double` |
| Timestamp | `timestamp: Date` |

`systemSamples` is always full interleaved stereo `[L0, R0, L1, R1, ...]`. The library never folds it to mono.

### ChannelLayout

Records the actual WAV channel layout in `RecordingMetadata`. Old recordings without this field decode as `blended`.

| Value | Swift | C# | Meaning |
|-------|-------|-----|---------|
| Blended | `.blended` | `Blended` | Mic mixed into both channels |
| Separated stereo | `.separatedStereo` | `SeparatedStereo` | Ch1 = mic, Ch2 = system mono-fold |
| Mono | `.mono` | `Mono` | Single mono channel |

### MixingStrategy

| Value | Swift | C# | WAV layout |
|-------|-------|-----|-----------|
| Blended (default) | `.blended` | `Blended` | mic+sysL / mic+sysR |
| Separated | `.separated` | `Separated` | mic only / system (L+R)/2 |
| Multichannel | `.multichannel` | `Multichannel` | same as separated (reserved) |

### AudioLevels

Real-time audio level metering.

| Property | Swift | C# |
|----------|-------|-----|
| Mic level | `micLevel: Float` | `MicLevel: float` |
| System level | `systemLevel: Float` | `SystemLevel: float` |
| Peak mic | `peakMicLevel: Float` | `PeakMicLevel: float` |
| Peak system | `peakSystemLevel: Float` | `PeakSystemLevel: float` |

### AudioSource

Represents a discovered audio device.

| Property | Swift | C# |
|----------|-------|-----|
| ID | `id: String` | `Id: string` |
| Name | `name: String` | `Name: string` |
| Type | `type: AudioTrackType` | `Type: AudioTrackType` |
| Default | `isDefault: Bool` | `IsDefault: bool` |
| Transport | `transportType: AudioTransportType?` | `TransportType: AudioTransportType?` |

### CaptureError

| Variant | Swift | C# |
|---------|-------|-----|
| Permission denied | `.permissionDenied` | `PermissionDenied` |
| Device unavailable | `.deviceNotAvailable` | `DeviceNotAvailable` |
| Config failed | `.configurationFailed(String)` | `ConfigurationFailed(string)` |
| Encoding failed | `.encodingFailed(String)` | `EncodingFailed(string)` |
| Encryption failed | `.encryptionFailed(String)` | `EncryptionFailed(string)` |
| Storage error | `.storageError(String)` | `StorageError(string)` |
| Timeout | `.timeout` | `Timeout` |
| Unknown | `.unknown(String)` | `Unknown(string)` |

### AudioTrack

| Property | Swift | C# | Notes |
|----------|-------|-----|-------|
| Type | `type: AudioTrackType` | `Type: AudioTrackType` | |
| Channel | `channel: AudioChannel` | `Channel: AudioChannel` | |
| Label | `label: String?` | `Label: string?` | Omitted from JSON when nil |

### Enums

**AudioTrackType**: `mic`, `system`

**AudioChannel**: `left` (L), `right` (R), `center` (C), `stereo` (LR)

**AudioTransportType**: `builtIn`, `bluetooth`, `bluetoothLE`, `usb`, `virtual`, `unknown`

**MixingStrategy**: `blended` (default), `separated`, `multichannel` — see [DIARIZATION.md](DIARIZATION.md)

**ChannelLayout**: `blended` (default), `separatedStereo`, `mono`
