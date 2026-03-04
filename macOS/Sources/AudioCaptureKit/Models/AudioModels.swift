import Foundation

/// Represents the type of an audio track.
public enum AudioTrackType: String, Sendable, Codable {
    /// Microphone input (what the user speaks).
    case mic

    /// System audio (what the user hears).
    case system
}

/// Represents the stereo channel assignment for an audio track.
public enum AudioChannel: String, Sendable, Codable {
    /// Left stereo channel.
    case left = "L"

    /// Right stereo channel.
    case right = "R"

    /// Center (mixed into both channels).
    case center = "C"

    /// Full stereo (present in both channels).
    case stereo = "LR"
}

/// Describes an audio track within a recording.
public struct AudioTrack: Sendable, Codable, Equatable {
    /// The source type of this track.
    public let type: AudioTrackType

    /// The stereo channel this track is assigned to.
    public let channel: AudioChannel

    /// Optional human-readable label for this track (e.g. "Mic (Local)").
    public let label: String?

    private enum CodingKeys: String, CodingKey {
        case type, channel, label
    }

    public init(type: AudioTrackType, channel: AudioChannel, label: String? = nil) {
        self.type = type
        self.channel = channel
        self.label = label
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(channel, forKey: .channel)
        try container.encodeIfPresent(label, forKey: .label)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(AudioTrackType.self, forKey: .type)
        channel = try container.decode(AudioChannel.self, forKey: .channel)
        label = try container.decodeIfPresent(String.self, forKey: .label)
    }
}

/// Raw per-channel audio samples from one processing cycle (~100 ms window).
///
/// Delivered via ``AudioCaptureDelegate/captureSession(_:didProduceChannelBuffers:)``
/// before mixing and file writing. All samples are Float32, normalized to [-1.0, 1.0],
/// at the session's configured sample rate.
///
/// ``systemSamples`` is full interleaved stereo [L0, R0, L1, R1, ...]. The library
/// does not fold, downsample, or otherwise modify system audio.
public struct ChannelBuffers: Sendable {
    /// Mono microphone samples. Empty when mic capture is disabled.
    public let micSamples: [Float]

    /// Interleaved stereo system audio [L0, R0, L1, R1, ...].
    /// Empty when system capture is disabled.
    public let systemSamples: [Float]

    /// Sample rate of both arrays, in Hz.
    public let sampleRate: Double

    /// Wall-clock timestamp at the start of this buffer window.
    public let timestamp: Date

    public init(micSamples: [Float], systemSamples: [Float], sampleRate: Double, timestamp: Date = Date()) {
        self.micSamples = micSamples
        self.systemSamples = systemSamples
        self.sampleRate = sampleRate
        self.timestamp = timestamp
    }
}

/// Records the actual WAV channel layout for downstream decoders.
public enum ChannelLayout: String, Sendable, Codable {
    /// Mic mixed into both channels (legacy/blended strategy).
    case blended
    /// Ch1 (Left) = mic only, Ch2 (Right) = system audio mono-folded (L+R)/2.
    case separatedStereo = "separatedStereo"
    /// Single mono channel.
    case mono
}

/// Describes the transport type of an audio device.
public enum AudioTransportType: String, Sendable, Equatable {
    case builtIn
    case bluetooth
    case bluetoothLE
    case usb
    case virtual
    case unknown
}

/// Describes an available audio source on the system.
public struct AudioSource: Sendable, Equatable, Identifiable {
    /// Unique identifier for this audio source.
    public let id: String

    /// Human-readable name of the audio source.
    public let name: String

    /// The type of audio this source provides.
    public let type: AudioTrackType

    /// Whether this is the default device for its type.
    public let isDefault: Bool

    /// The transport type of this audio device (e.g. built-in, Bluetooth).
    public let transportType: AudioTransportType?

    public init(
        id: String,
        name: String,
        type: AudioTrackType,
        isDefault: Bool,
        transportType: AudioTransportType? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isDefault = isDefault
        self.transportType = transportType
    }
}

/// Real-time audio level metering information.
public struct AudioLevels: Sendable, Equatable {
    /// Current RMS level of the microphone input (0.0 to 1.0).
    public let micLevel: Float

    /// Current RMS level of the system audio input (0.0 to 1.0).
    public let systemLevel: Float

    /// Peak level of the microphone input (0.0 to 1.0).
    public let peakMicLevel: Float

    /// Peak level of the system audio input (0.0 to 1.0).
    public let peakSystemLevel: Float

    public init(
        micLevel: Float = 0,
        systemLevel: Float = 0,
        peakMicLevel: Float = 0,
        peakSystemLevel: Float = 0
    ) {
        self.micLevel = micLevel
        self.systemLevel = systemLevel
        self.peakMicLevel = peakMicLevel
        self.peakSystemLevel = peakSystemLevel
    }

    /// Default zero levels.
    public static let zero = Self()
}

/// Real-time diagnostics for debugging the capture pipeline.
public struct CaptureSessionDiagnostics: Sendable {
    /// Number of mic audio callbacks received.
    public var micCallbackCount = 0
    /// Number of system audio callbacks received.
    public var systemCallbackCount = 0
    /// Total mic samples written to buffer.
    public var micSamplesTotal = 0
    /// Total system samples written to buffer (interleaved stereo count).
    public var systemSamplesTotal = 0
    /// Format description of last mic buffer received.
    public var micFormat = "—"
    /// Format description of last system buffer received.
    public var systemFormat = "—"
    /// Total bytes written to file.
    public var bytesWritten = 0
    /// Number of processBuffers cycles that produced output.
    public var mixCycles = 0

    public init() {}
}
