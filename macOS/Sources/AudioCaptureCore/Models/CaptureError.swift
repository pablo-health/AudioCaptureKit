import Foundation

/// Errors that can occur during audio capture operations.
public enum CaptureError: Error, Sendable, Equatable {
    /// The user denied the required system permission.
    case permissionDenied

    /// The requested audio device is not available.
    case deviceNotAvailable

    /// The capture session could not be configured with the given parameters.
    case configurationFailed(String)

    /// Audio encoding failed during processing.
    case encodingFailed(String)

    /// Encryption of audio data failed.
    case encryptionFailed(String)

    /// An error occurred writing to or reading from storage.
    case storageError(String)

    /// The operation timed out.
    case timeout

    /// An unknown or unexpected error occurred.
    case unknown(String)
}

extension CaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Permission denied. Please grant the required audio recording permission."
        case .deviceNotAvailable:
            "The requested audio device is not available."
        case let .configurationFailed(reason):
            "Configuration failed: \(reason)"
        case let .encodingFailed(reason):
            "Encoding failed: \(reason)"
        case let .encryptionFailed(reason):
            "Encryption failed: \(reason)"
        case let .storageError(reason):
            "Storage error: \(reason)"
        case .timeout:
            "The operation timed out."
        case let .unknown(reason):
            "Unknown error: \(reason)"
        }
    }
}
