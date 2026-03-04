@testable import AudioCaptureKit
import Foundation
import Testing

@Suite("ChannelLayout — JSON coding and backward compatibility")
struct ChannelLayoutTests {

    @Test("separatedStereo encodes and round-trips correctly")
    func separatedStereo_roundTrips() throws {
        let layout = ChannelLayout.separatedStereo
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(ChannelLayout.self, from: data)
        #expect(decoded == .separatedStereo)
    }

    @Test("Missing channelLayout in JSON defaults to blended (backward compat)")
    func missingChannelLayout_defaultsToBlended() throws {
        // Build a RecordingMetadata JSON without "channelLayout" key
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000000",
            "duration": 60.0,
            "fileURL": "file:///tmp/test.wav",
            "checksum": "abc",
            "isEncrypted": false,
            "createdAt": "2024-01-01T00:00:00Z",
            "tracks": []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(RecordingMetadata.self, from: json)
        #expect(metadata.channelLayout == .blended)
    }

    @Test("AudioTrack label round-trips through JSON")
    func audioTrack_label_roundTrips() throws {
        let track = AudioTrack(type: .mic, channel: .left, label: "Mic (Local)")
        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(AudioTrack.self, from: data)
        #expect(decoded.label == "Mic (Local)")
    }

    @Test("AudioTrack nil label is omitted from JSON output")
    func audioTrack_nilLabel_omittedFromJSON() throws {
        let track = AudioTrack(type: .mic, channel: .left)
        let data = try JSONEncoder().encode(track)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["label"] == nil)
    }

    @Test("ChannelBuffers is constructible with empty arrays")
    func channelBuffers_emptyArraysAreValid() {
        let buffers = ChannelBuffers(micSamples: [], systemSamples: [], sampleRate: 48000)
        #expect(buffers.micSamples.isEmpty)
        #expect(buffers.systemSamples.isEmpty)
    }

    @Test("ChannelBuffers systemSamples count is even (interleaved stereo contract)")
    func channelBuffers_systemSamples_isFullStereo() {
        let system: [Float] = [0.1, 0.2, 0.3, 0.4] // 2 stereo frames
        let buffers = ChannelBuffers(micSamples: [], systemSamples: system, sampleRate: 48000)
        #expect(buffers.systemSamples.count % 2 == 0)
    }
}
