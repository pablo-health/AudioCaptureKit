@testable import AudioCaptureKit
import AVFoundation
import Foundation
import os
import Testing

/// Proves the streaming AAC encoder emits a real, decodable ADTS stream — not
/// just plausible bytes. The strongest local proxy for "AssemblyAI can
/// transcribe it" is "AVFoundation can decode it back to the original tone."
@Suite("AACStreamEncoder")
struct AACStreamEncoderTests {

    private let logger = Logger(subsystem: "com.audiocapturekit.tests", category: "AACStreamEncoderTests")

    @Test("Encoded ADTS frames start with a valid syncword and decode back to the source tone")
    func encodesDecodableMonoTone() throws {
        let sampleRate = 48000.0
        let tone = 440.0
        let seconds = 2.0

        let sink = FrameSinkBox()
        let encoder = try #require(
            AACStreamEncoder(sampleRate: sampleRate, channels: 1, bitRate: 64000, logger: logger) {
                sink.append($0)
            }
        )

        // Feed the tone in ~1-second chunks, mirroring the capture graph.
        let samples = sineSamples(frequency: tone, sampleRate: sampleRate, seconds: seconds, channels: 1)
        for chunk in chunked(samples, into: Int(sampleRate)) {
            encoder.encode(chunk)
        }
        encoder.finish()

        let frames = sink.frames
        #expect(frames.count > 1, "encoder produced no ADTS frames")
        // Every frame must carry the ADTS syncword (0xFFF) in its first 12 bits.
        for frame in frames {
            #expect(frame.count > 7, "ADTS frame shorter than its header")
            #expect(frame[0] == 0xFF && (frame[1] & 0xF0) == 0xF0, "frame missing ADTS syncword")
        }

        // Write the concatenated ADTS stream and decode it back.
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let aacURL = tempDir.appendingPathComponent("tone.aac")
        var stream = Data()
        frames.forEach { stream.append($0) }
        try stream.write(to: aacURL)

        let decoded = try decodePCM(from: aacURL)
        #expect(decoded.sampleRate == sampleRate, "decoded sample rate \(decoded.sampleRate) != \(sampleRate)")
        // AAC priming/padding shifts length slightly; allow 5% duration slack.
        let decodedSeconds = Double(decoded.samples.count) / decoded.sampleRate
        #expect(abs(decodedSeconds - seconds) < seconds * 0.05, "decoded duration \(decodedSeconds)s != \(seconds)s")
        let freq = dominantFrequency(decoded.samples, sampleRate: decoded.sampleRate)
        #expect(abs(freq - tone) < 40, "decoded tone \(freq)Hz != source \(tone)Hz")

        // Compression actually happened: 2s mono AAC @ 64kbps ≈ 16 KB, vs
        // ~192 KB of raw 16-bit PCM.
        let aacBytes = try #require(FileManager.default.attributesOfItem(atPath: aacURL.path)[.size] as? Int)
        let rawPCMBytes = Int(sampleRate * seconds) * 2
        #expect(aacBytes < rawPCMBytes / 4, "AAC (\(aacBytes)B) not materially smaller than PCM (\(rawPCMBytes)B)")
    }

    @Test("Stereo interleaved input encodes and decodes as two channels")
    func encodesStereo() throws {
        let sampleRate = 48000.0
        let sink = FrameSinkBox()
        let encoder = try #require(
            AACStreamEncoder(sampleRate: sampleRate, channels: 2, bitRate: 64000, logger: logger) {
                sink.append($0)
            }
        )
        let samples = sineSamples(frequency: 660, sampleRate: sampleRate, seconds: 1.5, channels: 2)
        for chunk in chunked(samples, into: Int(sampleRate) * 2) {
            encoder.encode(chunk)
        }
        encoder.finish()

        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let aacURL = tempDir.appendingPathComponent("stereo.aac")
        var stream = Data()
        sink.frames.forEach { stream.append($0) }
        try stream.write(to: aacURL)

        let file = try AVAudioFile(forReading: aacURL)
        #expect(file.processingFormat.channelCount == 2, "decoded stream is not stereo")
        #expect(file.length > 0, "decoded stereo stream is empty")
    }

    // MARK: - ADTS header

    @Test("ADTS header encodes frame length and 48kHz/mono config correctly")
    func adtsHeaderFields() {
        let header = AACStreamEncoder.adtsHeader(payloadLength: 100, sampleRate: 48000, channels: 1)
        #expect(header.count == 7)
        #expect(header[0] == 0xFF)
        #expect(header[1] == 0xF1, "MPEG-4, layer 0, no-CRC bits wrong")
        // freq index for 48kHz is 3 → bits 2..5 of byte 2.
        #expect((Int(header[2]) >> 2) & 0xF == 3, "sampling frequency index != 3 (48kHz)")
        // frame length = payload + 7 = 107, spread across bytes 3..5.
        let frameLen = (Int(header[3] & 0x3) << 11) | (Int(header[4]) << 3) | (Int(header[5]) >> 5)
        #expect(frameLen == 107, "encoded frame length \(frameLen) != 107")
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aactest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Interleaved Float32 sine samples (every channel carries the same tone).
    private func sineSamples(
        frequency: Double,
        sampleRate: Double,
        seconds: Double,
        channels: Int
    ) -> [Float] {
        let frames = Int(sampleRate * seconds)
        var out = [Float](repeating: 0, count: frames * channels)
        for frame in 0 ..< frames {
            let value = Float(sin(2.0 * .pi * frequency * Double(frame) / sampleRate)) * 0.5
            for ch in 0 ..< channels {
                out[frame * channels + ch] = value
            }
        }
        return out
    }

    /// Decodes an audio file to mono Float samples (channel 0) + its sample rate.
    private func decodePCM(from url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let channelData = try #require(buffer.floatChannelData)
        let count = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            samples[i] = channelData[0][i]
        }
        return (samples, format.sampleRate)
    }

    /// Zero-crossing frequency estimate: crossings-per-second ≈ 2 × frequency.
    private func dominantFrequency(_ samples: [Float], sampleRate: Double) -> Double {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for i in 1 ..< samples.count where (samples[i - 1] < 0) != (samples[i] < 0) {
            crossings += 1
        }
        return Double(crossings) / 2.0 / (Double(samples.count) / sampleRate)
    }
}

/// Thread-safe collector for emitted ADTS frames.
private final class FrameSinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Data] = []

    func append(_ frame: Data) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(frame)
    }

    var frames: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Splits `array` into consecutive slices of at most `size` elements.
private func chunked<Element>(_ array: [Element], into size: Int) -> [[Element]] {
    guard size > 0 else { return [array] }
    return stride(from: 0, to: array.count, by: size).map {
        Array(array[$0 ..< Swift.min($0 + size, array.count)])
    }
}
