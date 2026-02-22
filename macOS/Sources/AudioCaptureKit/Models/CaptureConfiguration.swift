import Foundation

/// Configuration for an audio capture session.
public struct CaptureConfiguration: Sendable {
    /// Audio sample rate in Hz. Default is 48000.
    public let sampleRate: Double

    /// Bit depth for audio samples. Default is 16.
    public let bitDepth: Int

    /// Number of audio channels. Default is 2 (stereo).
    public let channels: Int

    /// Optional encryptor for encrypting audio data at rest.
    public let encryptor: (any CaptureEncryptor)?

    /// Directory where recorded files will be stored.
    public let outputDirectory: URL

    /// Optional maximum recording duration in seconds.
    public let maxDuration: TimeInterval?

    /// Optional specific microphone device ID to use instead of the system default.
    public let micDeviceID: String?

    /// Whether to capture microphone audio. Default is true.
    public let enableMicCapture: Bool

    /// Whether to capture system audio. Default is true.
    public let enableSystemCapture: Bool

    public init(
        sampleRate: Double = 48000,
        bitDepth: Int = 16,
        channels: Int = 2,
        encryptor: (any CaptureEncryptor)? = nil,
        outputDirectory: URL,
        maxDuration: TimeInterval? = nil,
        micDeviceID: String? = nil,
        enableMicCapture: Bool = true,
        enableSystemCapture: Bool = true
    ) {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.encryptor = encryptor
        self.outputDirectory = outputDirectory
        self.maxDuration = maxDuration
        self.micDeviceID = micDeviceID
        self.enableMicCapture = enableMicCapture
        self.enableSystemCapture = enableSystemCapture
    }
}
