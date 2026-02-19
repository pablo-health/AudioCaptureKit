// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioCaptureKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AudioCaptureKit",
            targets: ["AudioCaptureKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.12.0")
    ],
    targets: [
        .target(
            name: "AudioCaptureKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .testTarget(
            name: "AudioCaptureKitTests",
            dependencies: [
                "AudioCaptureKit",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
