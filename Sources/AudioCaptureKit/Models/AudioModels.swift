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

    public init(type: AudioTrackType, channel: AudioChannel) {
        self.type = type
        self.channel = channel
    }
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

    public init(id: String, name: String, type: AudioTrackType, isDefault: Bool, transportType: AudioTransportType? = nil) {
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
    public static let zero = AudioLevels()
}

/// Real-time diagnostics for debugging the capture pipeline.
public struct CaptureSessionDiagnostics: Sendable {
    /// Number of mic audio callbacks received.
    public var micCallbackCount: Int = 0
    /// Number of system audio callbacks received.
    public var systemCallbackCount: Int = 0
    /// Total mic samples written to buffer.
    public var micSamplesTotal: Int = 0
    /// Total system samples written to buffer (interleaved stereo count).
    public var systemSamplesTotal: Int = 0
    /// Format description of last mic buffer received.
    public var micFormat: String = "—"
    /// Format description of last system buffer received.
    public var systemFormat: String = "—"
    /// Total bytes written to file.
    public var bytesWritten: Int = 0
    /// Number of processBuffers cycles that produced output.
    public var mixCycles: Int = 0

    public init() {}
}
