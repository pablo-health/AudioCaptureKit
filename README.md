# AudioCaptureKit

[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/pablo-health/AudioCaptureKit/badge)](https://scorecard.dev/viewer/?uri=github.com/pablo-health/AudioCaptureKit)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/12007/badge)](https://www.bestpractices.dev/projects/12007)

Cross-platform audio capture library — microphone + system audio mixed into a single stereo recording with AES-256-GCM encryption.

## Platform Support

| Platform | Language | Audio API | Directory |
|----------|----------|-----------|-----------|
| macOS 14+ | Swift 6 | Core Audio Taps + AVFoundation | `macOS/` |
| Windows 10+ | C# / .NET 10 | WASAPI (via NAudio) | `csharp/` |

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
- .NET 10

### Building

```bash
dotnet build csharp/AudioCapture/AudioCapture.csproj -c Release
dotnet test csharp/AudioCapture.Tests/AudioCapture.Tests.csproj
```

### Quick Start

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

See `csharp/` for source code.

## License

This project is licensed under the [GNU Affero General Public License v3.0](LICENSE).

For commercial licensing options, contact [kurtn@pablo.health](mailto:kurtn@pablo.health).
