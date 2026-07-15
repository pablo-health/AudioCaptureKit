@testable import AudioCaptureKit
import AVFoundation
import Foundation
import Testing

/// Sustained-capture soak: drives the real ``CompositeCaptureSession`` graph
/// from looped file sources for a long, wall-clock **real-time** run and
/// asserts the ring buffer stays clean the whole way — no overflow, steady
/// throughput, no stall.
///
/// Why real-time (not accelerated): the failure this guards against is slow —
/// a buffer that drifts, leaks, or overflows only after minutes of continuous
/// producer/consumer traffic. Accelerated pacing would push the samples through
/// in seconds and could report false overflow by out-running the writer; the
/// point is to prove the graph survives a *real* 50-minute session.
///
/// Duration is env-tunable via ``SOAK_SECONDS`` so PR CI runs a short soak and
/// the weekly workflow runs the full ~50-minute one against the same code path.
@Suite("Capture soak / buffer reliability")
struct CaptureSoakTests {
    @Test("Sustained real-time capture keeps the ring buffer clean (no overflow, steady throughput)")
    func sustainedCaptureStaysClean() async throws {
        let seconds = ProcessInfo.processInfo.environment["SOAK_SECONDS"].flatMap { Double($0) } ?? 20.0
        let sampleRate = 48000.0

        let tempDir = try makeTempDirectory(prefix: "acksoak")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diag = try await runSoak(seconds: seconds, sampleRate: sampleRate, in: tempDir)

        // 1. The load-bearing assertion: not a single dropped sample across the
        //    entire soak, on either channel.
        #expect(
            diag.micOverflowSamples == 0,
            "mic buffer overflowed after \(seconds)s: \(diag.micOverflowSamples) samples dropped"
        )
        #expect(
            diag.systemOverflowSamples == 0,
            "system buffer overflowed after \(seconds)s: \(diag.systemOverflowSamples) samples dropped"
        )

        // 2. Both sources delivered buffers throughout, and the mixer kept
        //    cycling — a stall would leave these near their start values.
        #expect(diag.micCallbackCount > 0, "mic source stopped delivering buffers")
        #expect(diag.systemCallbackCount > 0, "system source stopped delivering buffers")
        #expect(diag.mixCycles >= 1, "mixer never completed a cycle")

        // 3. Throughput stayed steady: bytes written track the elapsed real time.
        //    A stall or silent death mid-soak shows up as a large shortfall. Use
        //    a generous floor (>= 50% of a 16-bit stereo stream) so normal
        //    start/stop edges and pacing jitter don't flake, while a real stall
        //    (which drops toward zero) still trips it.
        let minBytesPerSecond = sampleRate * 2 /* ch */ * 2 /* bytes/sample */ * 0.5
        let expectedFloor = Int(minBytesPerSecond * seconds)
        #expect(
            diag.bytesWritten >= expectedFloor,
            "throughput shortfall: wrote \(diag.bytesWritten) bytes in \(seconds)s, expected >= \(expectedFloor)"
        )
    }

    // MARK: - Soak harness

    /// Wire looped mic + system fixtures through the real graph, capture for
    /// `seconds` of wall-clock real time, and return the session diagnostics.
    private func runSoak(
        seconds: Double,
        sampleRate: Double,
        in tempDir: URL
    ) async throws -> CaptureSessionDiagnostics {
        // Short fixtures, looped for the whole soak. Content is irrelevant to
        // buffer reliability; distinct tones per channel keep them realistic.
        let micFixture = tempDir.appendingPathComponent("mic.wav")
        let systemFixture = tempDir.appendingPathComponent("system.wav")
        try writeSineWAV(to: micFixture, frequency: 440, sampleRate: sampleRate, channels: 1, duration: 3.0)
        try writeSineWAV(to: systemFixture, frequency: 880, sampleRate: sampleRate, channels: 2, duration: 3.0)

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
            exportRawPCM: true
        )
        let session = CompositeCaptureSession(
            configuration: config,
            micSource: FilePlayerCaptureSource(fileURL: micFixture, format: micFormat, loop: true),
            systemSource: FilePlayerCaptureSource(fileURL: systemFixture, format: systemFormat, loop: true)
        )

        try session.configure(config)
        try await session.startCapture()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        _ = try await session.stopCapture()
        return session.diagnostics
    }

    // MARK: - Fixtures (self-contained; the integration suite's helpers are private)

    private func makeTempDirectory(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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
