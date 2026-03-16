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

    /// URLs of PCM sidecar files. [0] = mic (mono), [1] = system (stereo interleaved).
    /// Uses `.enc.pcm` extension when encrypted. Empty unless exportRawPCM was enabled.
    public let rawPCMFileURLs: [URL]

    public init(
        fileURL: URL,
        duration: TimeInterval,
        metadata: RecordingMetadata,
        checksum: String,
        rawPCMFileURLs: [URL] = []
    ) {
        self.fileURL = fileURL
        self.duration = duration
        self.metadata = metadata
        self.checksum = checksum
        self.rawPCMFileURLs = rawPCMFileURLs
    }
}
