// swift-tools-version: 6.0
import PackageDescription

// Two targets, split by what the code actually needs rather than by where it
// happened to be written.
//
// `AudioCaptureCore` is Foundation + Crypto only: the models, the encrypted file
// format, and the protocols. None of it touches AVFoundation, ScreenCaptureKit
// or CoreAudio, so it builds anywhere Swift does — including Linux, and
// including a consumer that wants the file format or the `CaptureEncryptor`
// protocol without a capture graph attached.
//
// `AudioCaptureKit` is the macOS capture graph: CoreAudio taps, ScreenCaptureKit,
// AVFoundation conversion and mixing. It re-exports the core, so an existing
// `import AudioCaptureKit` sees exactly the same API as before.
//
// Why: the package was gated `.macOS(.v14)` for the capture graph's sake, which
// pinned ~1000 Foundation-only lines to macOS along with it. Downstream that
// forced pablo-companion to invent its own encryptor protocol purely to avoid
// naming a type in here, so its Foundation-only target could keep building on
// Linux CI.
let package = Package(
    name: "AudioCaptureKit",
    platforms: [
        // Constrains Apple platforms only; Linux is unconstrained. That is what
        // lets AudioCaptureCore build there, while AudioCaptureKit will not —
        // correctly, since it imports AVFoundation.
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AudioCaptureKit",
            targets: ["AudioCaptureKit"]
        ),
        .library(
            name: "AudioCaptureCore",
            targets: ["AudioCaptureCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0")
    ],
    targets: [
        .target(
            name: "AudioCaptureCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "macOS/Sources/AudioCaptureCore"
        ),
        .target(
            name: "AudioCaptureKit",
            dependencies: [
                "AudioCaptureCore",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "macOS/Sources/AudioCaptureKit"
        ),
        .testTarget(
            name: "AudioCaptureKitTests",
            dependencies: [
                "AudioCaptureKit"
            ],
            path: "macOS/Tests/AudioCaptureKitTests"
        )
    ]
)
