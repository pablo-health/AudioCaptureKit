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
            return "Permission denied. Please grant the required audio recording permission."
        case .deviceNotAvailable:
            return "The requested audio device is not available."
        case .configurationFailed(let reason):
            return "Configuration failed: \(reason)"
        case .encodingFailed(let reason):
            return "Encoding failed: \(reason)"
        case .encryptionFailed(let reason):
            return "Encryption failed: \(reason)"
        case .storageError(let reason):
            return "Storage error: \(reason)"
        case .timeout:
            return "The operation timed out."
        case .unknown(let reason):
            return "Unknown error: \(reason)"
        }
    }
}
