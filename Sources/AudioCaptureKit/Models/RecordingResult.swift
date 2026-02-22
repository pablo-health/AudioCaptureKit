import Foundation

/// The result of a completed recording session.
public struct RecordingResult: Sendable, Equatable {
    /// URL of the recorded audio file on disk.
    public let fileURL: URL

    /// Total duration of the recording in seconds.
    public let duration: TimeInterval

    /// Associated metadata for the recording.
    public let metadata: RecordingMetadata

    /// SHA-256 checksum of the recorded file.
    public let checksum: String

    public init(fileURL: URL, duration: TimeInterval, metadata: RecordingMetadata, checksum: String) {
        self.fileURL = fileURL
        self.duration = duration
        self.metadata = metadata
        self.checksum = checksum
    }
}
