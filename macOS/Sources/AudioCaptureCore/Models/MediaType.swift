import Foundation

/// The type of media being captured.
public enum MediaType: String, Sendable, Codable {
    /// Audio-only capture.
    case audio

    /// Video capture (future extensibility).
    case video
}
