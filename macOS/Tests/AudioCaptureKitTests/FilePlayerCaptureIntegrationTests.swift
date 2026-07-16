@testable import AudioCaptureKit
import AVFoundation
import Foundation
import Testing

/// End-to-end tests that drive the real ``CompositeCaptureSession`` capture
/// graph from file fixtures instead of live hardware, via injected
/// ``FilePlayerCaptureSource``s. These exercise the entire mix / convert /
/// buffer / write pipeline — the part no unit test reaches — without needing a
/// microphone, a system-audio tap, or their privacy permissions.
@Suite("FilePlayerCaptureSource integration")
struct FilePlayerCaptureIntegrationTests {

    @Test("Injected mic + system files flow through the real graph to a mixed WAV + sidecars")
    func fileInjectionProducesMixedWAVAndSidecars() async throws {
        let sampleRate = 48000.0
        let micTone = 440.0 // therapist channel (left)
        let systemTone = 880.0 // client / system channel (right)

        let tempDir = try makeTempDirectory(prefix: "acktest")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (session, result) = try await runSeparatedCapture(
            tempDir: tempDir,
            micTone: micTone,
            systemTone: systemTone,
            sampleRate: sampleRate,
            captureDuration: 2.5
        )

        try assertGraphRanCleanly(session.diagnostics)
        try assertMixedWAV(result, sampleRate: sampleRate, micTone: micTone, systemTone: systemTone)
        try assertSidecars(result)
    }

    @Test("AAC sidecars: the real graph writes small, decodable .aac channels")
    func fileInjectionProducesAACSidecars() async throws {
        let sampleRate = 48000.0
        let tempDir = try makeTempDirectory(prefix: "acktest-aac")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (session, result) = try await runSeparatedCapture(
            tempDir: tempDir,
            micTone: 440,
            systemTone: 880,
            sampleRate: sampleRate,
            captureDuration: 3.0,
            sidecarFormat: .aacADTS
        )

        try assertGraphRanCleanly(session.diagnostics)
        #expect(result.rawPCMFileURLs.count == 2, "expected mic + system AAC sidecars")

        for (index, url) in result.rawPCMFileURLs.enumerated() {
            #expect(url.pathExtension == "aac", "sidecar \(url.lastPathComponent) is not .aac")
            let size = try (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            #expect(size > 0, "AAC sidecar \(url.lastPathComponent) is empty")

            // Decodes as real AAC audio, and is far smaller than the equivalent
            // raw PCM (mono ~2 bytes/frame, stereo ~4) would have been.
            let file = try AVAudioFile(forReading: url)
            #expect(file.length > 0, "AAC sidecar \(url.lastPathComponent) decoded empty")
            let channels = index == 0 ? 1 : 2
            let approxRawPCM = Int(sampleRate * 3.0) * 2 * channels
            #expect(
                size < approxRawPCM / 4,
                "AAC sidecar (\(size)B) not materially smaller than PCM (\(approxRawPCM)B)"
            )
        }
    }

    @Test("A file source is restartable — the probe/start cycle does not consume the fixture head")
    func fileSourceIsRestartable() async throws {
        let sampleRate = 48000.0
        let tempDir = try makeTempDirectory(prefix: "acktest-restart")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fixture = tempDir.appendingPathComponent("tone.wav")
        try writeSineWAV(to: fixture, frequency: 440, sampleRate: sampleRate, channels: 1, duration: 1.0)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ))
        let source = FilePlayerCaptureSource(fileURL: fixture, format: format, pacing: .accelerated(factor: 20))

        // Two independent start cycles must both begin emitting from sampleTime 0.
        let first = try await firstSampleTime(of: source)
        let second = try await firstSampleTime(of: source)
        #expect(first == 0, "first start did not begin at the fixture head")
        #expect(second == 0, "restart did not rewind to the fixture head")
    }

    // MARK: - Capture harness

    /// Writes fixtures, wires them through the real graph with `.separated`
    /// mixing + raw sidecars, runs a capture, and returns the session + result.
    private func runSeparatedCapture(
        tempDir: URL,
        micTone: Double,
        systemTone: Double,
        sampleRate: Double,
        captureDuration: TimeInterval,
        sidecarFormat: SidecarAudioFormat = .rawPCM
    ) async throws -> (session: CompositeCaptureSession, result: RecordingResult) {
        let micFixture = tempDir.appendingPathComponent("mic-fixture.wav")
        let systemFixture = tempDir.appendingPathComponent("system-fixture.wav")
        try writeSineWAV(to: micFixture, frequency: micTone, sampleRate: sampleRate, channels: 1, duration: 4.0)
        try writeSineWAV(to: systemFixture, frequency: systemTone, sampleRate: sampleRate, channels: 2, duration: 4.0)

        let micFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ))
        let systemFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false
        ))

        let config = CaptureConfiguration(
            sampleRate: sampleRate,
            bitDepth: 16,
            channels: 2,
            outputDirectory: tempDir,
            enableMicCapture: true,
            enableSystemCapture: true,
            mixingStrategy: .separated,
            exportRawPCM: true,
            sidecarFormat: sidecarFormat
        )
        let session = CompositeCaptureSession(
            configuration: config,
            micSource: FilePlayerCaptureSource(fileURL: micFixture, format: micFormat, loop: true),
            systemSource: FilePlayerCaptureSource(fileURL: systemFixture, format: systemFormat, loop: true)
        )

        try session.configure(config)
        try await session.startCapture()
        try await Task.sleep(nanoseconds: UInt64(captureDuration * 1_000_000_000))
        let result = try await session.stopCapture()
        return (session, result)
    }

    /// Starts a source, records the first callback's sample time, then stops.
    private func firstSampleTime(of source: FilePlayerCaptureSource) async throws -> AVAudioFramePosition {
        let box = FirstTimeBox()
        try await source.start { _, time in box.record(time.sampleTime) }
        try await Task.sleep(nanoseconds: 60_000_000)
        await source.stop()
        return try #require(box.value)
    }

    // MARK: - Assertions

    private func assertGraphRanCleanly(_ diag: CaptureSessionDiagnostics) throws {
        #expect(diag.micCallbackCount > 0, "mic source never delivered a buffer")
        #expect(diag.systemCallbackCount > 0, "system source never delivered a buffer")
        #expect(diag.mixCycles >= 1, "no mix cycles completed")
        #expect(diag.bytesWritten > 0, "no bytes written")
        #expect(diag.micOverflowSamples == 0, "mic buffer overflowed: \(diag.micOverflowSamples) samples dropped")
        #expect(
            diag.systemOverflowSamples == 0,
            "system buffer overflowed: \(diag.systemOverflowSamples) samples dropped"
        )
    }

    private func assertMixedWAV(
        _ result: RecordingResult,
        sampleRate: Double,
        micTone: Double,
        systemTone: Double
    ) throws {
        let wavData = try Data(contentsOf: result.fileURL)
        #expect(wavData.count > 44, "mixed WAV has no audio payload")
        let header = try WAVHeader(parsing: wavData)
        #expect(header.channels == 2)
        #expect(header.sampleRate == UInt32(sampleRate))
        #expect(header.bitDepth == 16)

        // Channel separation: left carries the mic tone, right the system tone.
        let (left, right) = header.deinterleavedStereo(from: wavData)
        #expect(rms(left) > 500, "left (mic) channel is silent")
        #expect(rms(right) > 500, "right (system) channel is silent")
        let leftFreq = estimateFrequency(left, sampleRate: sampleRate)
        let rightFreq = estimateFrequency(right, sampleRate: sampleRate)
        #expect(abs(leftFreq - micTone) < 60, "left frequency \(leftFreq)Hz != mic tone \(micTone)Hz")
        #expect(abs(rightFreq - systemTone) < 90, "right frequency \(rightFreq)Hz != system tone \(systemTone)Hz")
    }

    private func assertSidecars(_ result: RecordingResult) throws {
        #expect(result.rawPCMFileURLs.count == 2, "expected mic + system sidecars")
        for url in result.rawPCMFileURLs {
            let size = try (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            #expect(size > 0, "sidecar \(url.lastPathComponent) is empty")
        }
    }

    // MARK: - Fixtures

    private func makeTempDirectory(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Generates a sine-wave WAV (16-bit PCM) with the given tone in every channel.
    private func writeSineWAV(
        to url: URL,
        frequency: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        duration: TimeInterval
    ) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false
        ))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )

        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channelData = try #require(buffer.floatChannelData)
        for channel in 0 ..< Int(channels) {
            let ptr = channelData[channel]
            for frame in 0 ..< Int(frameCount) {
                ptr[frame] = Float(sin(2.0 * .pi * frequency * Double(frame) / sampleRate)) * 0.5
            }
        }
        try file.write(from: buffer)
    }
}

// MARK: - Test helpers

private struct TestFailure: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}

/// Captures the first `sampleTime` seen from a capture callback in a thread-safe box.
private final class FirstTimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AVAudioFramePosition?

    func record(_ value: AVAudioFramePosition) {
        lock.lock()
        defer { lock.unlock() }
        if stored == nil { stored = value }
    }

    var value: AVAudioFramePosition? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Minimal WAV header parser for a canonical 44-byte PCM header.
private struct WAVHeader {
    let channels: UInt16
    let sampleRate: UInt32
    let bitDepth: UInt16
    let dataOffset: Int

    init(parsing data: Data) throws {
        guard data.count >= 44,
              data[0 ..< 4].elementsEqual([0x52, 0x49, 0x46, 0x46]), // "RIFF"
              data[8 ..< 12].elementsEqual([0x57, 0x41, 0x56, 0x45]) // "WAVE"
        else { throw TestFailure("not a RIFF/WAVE file") }
        channels = readUInt16LE(data, at: 22)
        sampleRate = readUInt32LE(data, at: 24)
        bitDepth = readUInt16LE(data, at: 34)
        dataOffset = 44
    }

    /// Splits interleaved 16-bit stereo PCM into left/right sample arrays.
    func deinterleavedStereo(from data: Data) -> (left: [Int16], right: [Int16]) {
        var left: [Int16] = []
        var right: [Int16] = []
        var offset = dataOffset
        let frameStride = 4 // 2 channels × 2 bytes
        while offset + frameStride <= data.count {
            left.append(Int16(bitPattern: readUInt16LE(data, at: offset)))
            right.append(Int16(bitPattern: readUInt16LE(data, at: offset + 2)))
            offset += frameStride
        }
        return (left, right)
    }
}

private func rms(_ samples: [Int16]) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sumSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    return (sumSquares / Double(samples.count)).squareRoot()
}

/// Estimates the dominant frequency of a tone via zero-crossing rate.
/// For a clean sine, crossings-per-second ≈ 2 × frequency.
private func estimateFrequency(_ samples: [Int16], sampleRate: Double) -> Double {
    guard samples.count > 1 else { return 0 }
    var crossings = 0
    for i in 1 ..< samples.count where (samples[i - 1] < 0) != (samples[i] < 0) {
        crossings += 1
    }
    let seconds = Double(samples.count) / sampleRate
    return Double(crossings) / 2.0 / seconds
}

private func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
}
