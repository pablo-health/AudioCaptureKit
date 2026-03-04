import Foundation

/// Metadata associated with a completed recording.
///
/// This struct is persisted alongside the audio file and contains
/// all information needed to identify, verify, and decrypt the recording.
public struct RecordingMetadata: Codable, Sendable, Equatable {
    /// Unique identifier for this recording.
    public let id: UUID

    /// Duration of the recording in seconds.
    public let duration: TimeInterval

    /// URL of the recording file on disk.
    public let fileURL: URL

    /// SHA-256 checksum of the audio file for integrity verification.
    public let checksum: String

    /// Whether the recording is encrypted.
    public let isEncrypted: Bool

    /// Timestamp when the recording was created.
    public let createdAt: Date

    /// Audio tracks in this recording.
    public let tracks: [AudioTrack]

    /// The encryption algorithm used (e.g., "AES-256-GCM"), if encrypted.
    public let encryptionAlgorithm: String?

    /// Identifier for the encryption key used, if encrypted.
    public let encryptionKeyId: String?

    /// The WAV channel layout used for this recording.
    public let channelLayout: ChannelLayout

    private enum CodingKeys: String, CodingKey {
        case id, duration, fileURL, checksum, isEncrypted, createdAt, tracks,
             encryptionAlgorithm, encryptionKeyId, channelLayout
    }

    public init(
        id: UUID = UUID(),
        duration: TimeInterval,
        fileURL: URL,
        checksum: String,
        isEncrypted: Bool,
        createdAt: Date = Date(),
        tracks: [AudioTrack],
        encryptionAlgorithm: String? = nil,
        encryptionKeyId: String? = nil,
        channelLayout: ChannelLayout = .blended
    ) {
        self.id = id
        self.duration = duration
        self.fileURL = fileURL
        self.checksum = checksum
        self.isEncrypted = isEncrypted
        self.createdAt = createdAt
        self.tracks = tracks
        self.encryptionAlgorithm = encryptionAlgorithm
        self.encryptionKeyId = encryptionKeyId
        self.channelLayout = channelLayout
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        fileURL = try container.decode(URL.self, forKey: .fileURL)
        checksum = try container.decode(String.self, forKey: .checksum)
        isEncrypted = try container.decode(Bool.self, forKey: .isEncrypted)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        tracks = try container.decode([AudioTrack].self, forKey: .tracks)
        encryptionAlgorithm = try container.decodeIfPresent(String.self, forKey: .encryptionAlgorithm)
        encryptionKeyId = try container.decodeIfPresent(String.self, forKey: .encryptionKeyId)
        channelLayout = (try? container.decodeIfPresent(ChannelLayout.self, forKey: .channelLayout)) ?? .blended
    }
}
