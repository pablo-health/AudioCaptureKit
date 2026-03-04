@testable import AudioCaptureKit
import Foundation
import Testing

@Suite("RecordingMetadata Tests")
struct RecordingMetadataTests {

    @Test("Codable round-trip encode and decode")
    func codableRoundTrip() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/recordings/test.enc.wav")
        let id = UUID()
        let createdAt = Date()

        let original = RecordingMetadata(
            id: id, duration: 3600.5, fileURL: fileURL,
            checksum: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
            isEncrypted: true, createdAt: createdAt,
            tracks: [
                AudioTrack(type: .mic, channel: .left),
                AudioTrack(type: .system, channel: .right),
            ],
            encryptionAlgorithm: "AES-256-GCM",
            encryptionKeyId: "key-001"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RecordingMetadata.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.duration == original.duration)
        #expect(decoded.fileURL == original.fileURL)
        #expect(decoded.checksum == original.checksum)
        #expect(decoded.isEncrypted == original.isEncrypted)
        #expect(decoded.tracks == original.tracks)
        #expect(decoded.encryptionAlgorithm == original.encryptionAlgorithm)
        #expect(decoded.encryptionKeyId == original.encryptionKeyId)
    }

    @Test("Codable round-trip without encryption fields")
    func codableRoundTripNoEncryption() throws {
        let original = RecordingMetadata(
            duration: 120.0,
            fileURL: URL(fileURLWithPath: "/tmp/test.wav"),
            checksum: "abcdef1234567890",
            isEncrypted: false,
            tracks: [AudioTrack(type: .mic, channel: .left)]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RecordingMetadata.self, from: data)

        #expect(decoded.isEncrypted == false)
        #expect(decoded.encryptionAlgorithm == nil)
        #expect(decoded.encryptionKeyId == nil)
    }

    @Test("Metadata equality")
    func metadataEquality() {
        let id = UUID()
        let url = URL(fileURLWithPath: "/tmp/test.wav")
        let date = Date()

        let meta1 = RecordingMetadata(
            id: id, duration: 60, fileURL: url, checksum: "abc",
            isEncrypted: false, createdAt: date,
            tracks: [AudioTrack(type: .mic, channel: .left)]
        )
        let meta2 = RecordingMetadata(
            id: id, duration: 60, fileURL: url, checksum: "abc",
            isEncrypted: false, createdAt: date,
            tracks: [AudioTrack(type: .mic, channel: .left)]
        )
        #expect(meta1 == meta2)
    }

    @Test("AudioTrack Codable round-trip")
    func audioTrackCodable() throws {
        let track = AudioTrack(type: .mic, channel: .left)
        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(AudioTrack.self, from: data)
        #expect(decoded.type == .mic)
        #expect(decoded.channel == .left)
    }

    @Test("AudioTrack channel values match schema")
    func audioTrackChannelValues() {
        #expect(AudioChannel.left.rawValue == "L")
        #expect(AudioChannel.right.rawValue == "R")
    }

    @Test("AudioTrackType values match schema")
    func audioTrackTypeValues() {
        #expect(AudioTrackType.mic.rawValue == "mic")
        #expect(AudioTrackType.system.rawValue == "system")
    }

    @Test("JSON output contains expected keys")
    func jsonContainsExpectedKeys() throws {
        let metadata = RecordingMetadata(
            duration: 30,
            fileURL: URL(fileURLWithPath: "/tmp/test.wav"),
            checksum: "abc123",
            isEncrypted: true,
            tracks: [],
            encryptionAlgorithm: "AES-256-GCM",
            encryptionKeyId: "key-1"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["id"] != nil)
        #expect(json?["duration"] as? Double == 30)
        #expect(json?["checksum"] as? String == "abc123")
        #expect(json?["isEncrypted"] as? Bool == true)
        #expect(json?["encryptionAlgorithm"] as? String == "AES-256-GCM")
        #expect(json?["encryptionKeyId"] as? String == "key-1")
    }

    @Test("channelLayout separatedStereo serializes correctly")
    func channelLayout_separatedStereo_serializesCorrectly() throws {
        let metadata = RecordingMetadata(
            duration: 30,
            fileURL: URL(fileURLWithPath: "/tmp/test.wav"),
            checksum: "abc",
            isEncrypted: false,
            tracks: [],
            channelLayout: .separatedStereo
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["channelLayout"] as? String == "separatedStereo")
    }

    @Test("Missing channelLayout in legacy JSON defaults to blended")
    func channelLayout_missingFromJSON_defaultsToBlended() throws {
        let json = Data("""
        {
            "id": "00000000-0000-0000-0000-000000000000",
            "duration": 60.0,
            "fileURL": "file:///tmp/test.wav",
            "checksum": "abc",
            "isEncrypted": false,
            "createdAt": "2024-01-01T00:00:00Z",
            "tracks": []
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(RecordingMetadata.self, from: json)
        #expect(metadata.channelLayout == .blended)
    }

    @Test("AudioTrack label is included in JSON when present")
    func audioTrack_labelIncludedInJSON_whenPresent() throws {
        let track = AudioTrack(type: .mic, channel: .left, label: "Mic (Local)")
        let data = try JSONEncoder().encode(track)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["label"] as? String == "Mic (Local)")
    }

    @Test("rawPCMFileURLs is empty by default in RecordingResult")
    func rawPCMFileURLs_emptyByDefault() {
        let result = RecordingResult(
            fileURL: URL(fileURLWithPath: "/tmp/test.wav"),
            duration: 30,
            metadata: RecordingMetadata(
                duration: 30,
                fileURL: URL(fileURLWithPath: "/tmp/test.wav"),
                checksum: "abc",
                isEncrypted: false,
                tracks: []
            ),
            checksum: "abc"
        )
        #expect(result.rawPCMFileURLs.isEmpty)
    }
}
