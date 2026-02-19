import Foundation

/// Protocol for encrypting captured audio data.
///
/// Implementations provide streaming encryption of audio buffers
/// as they are written to disk. The default implementation uses
/// AES-256-GCM via swift-crypto.
public protocol CaptureEncryptor: Sendable {
    /// Encrypts the provided data.
    /// - Parameter data: The plaintext audio data to encrypt.
    /// - Returns: The encrypted data including any necessary nonce/tag.
    /// - Throws: ``CaptureError/encryptionFailed(_:)`` if encryption fails.
    func encrypt(_ data: Data) throws -> Data

    /// Returns metadata about the encryption key for storage alongside the recording.
    /// - Returns: A dictionary with key metadata (e.g., key ID, creation date).
    func keyMetadata() -> [String: String]

    /// The name of the encryption algorithm used (e.g., "AES-256-GCM").
    var algorithm: String { get }
}
