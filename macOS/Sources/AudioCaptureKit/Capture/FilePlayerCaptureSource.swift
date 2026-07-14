import AVFoundation
import Foundation
import os

/// An ``AudioCaptureProvider`` that plays audio from a file instead of live
/// hardware, emitting buffers shaped like the real capture sources.
///
/// This lets the entire capture pipeline — format conversion, mixing, ring
/// buffering, and file writing — run deterministically and headlessly, without
/// a microphone, a system-audio tap, or the privacy permissions either
/// requires. Inject one as `micSource` and/or `systemSource` on
/// ``CompositeCaptureSession``.
///
/// The emitted buffers match the shape of the live sources:
/// - Microphone: mono Float32 at the file's sample rate.
/// - System audio: stereo (non-interleaved) Float32, typically at 48 kHz.
///
/// Pass the desired ``format`` to control channel count and sample rate; the
/// file is converted to that format once on first start.
///
/// ## Restartability
/// The source is **restartable**: each ``start(bufferCallback:)`` rewinds to the
/// beginning of the file. This matters because a capture session may probe a
/// source (start → sample briefly → stop) before the real capture begins — a
/// non-rewinding source would consume the head of the fixture during the probe.
///
/// ## Pacing
/// By default buffers are delivered in real time on a drift-corrected schedule,
/// so downstream timing behaves as it would with live audio. Use
/// ``Pacing/accelerated(factor:)`` to emit faster than real time when replaying
/// long fixtures in CI.
public final class FilePlayerCaptureSource: AudioCaptureProvider, @unchecked Sendable {

    /// Controls how quickly buffers are delivered relative to the audio clock.
    public enum Pacing: Sendable {
        /// Deliver buffers in real time (one second of audio per wall-clock second).
        case realtime
        /// Deliver `factor`× faster than real time. `factor > 1` speeds up replay.
        case accelerated(factor: Double)

        var speedFactor: Double {
            switch self {
            case .realtime: 1.0
            case let .accelerated(factor): max(factor, 0.0001)
            }
        }
    }

    private struct State {
        /// Per-channel float samples, non-interleaved. Loaded lazily on first start.
        var channels: [[Float]]?
        var totalFrames = 0
        var readIndex = 0
        var emittedFrames: Int64 = 0
        var pacingTask: Task<Void, Never>?
        var isCapturing = false
    }

    private let fileURL: URL
    private let outputFormat: AVAudioFormat
    private let chunkDuration: TimeInterval
    private let pacing: Pacing
    private let loop: Bool

    private let state = UnfairLock(State())

    private let logger = Logger(
        subsystem: "com.audiocapturekit",
        category: "FilePlayerCaptureSource"
    )

    /// Creates a file-backed capture source.
    ///
    /// - Parameters:
    ///   - fileURL: The audio file to play (any format `AVAudioFile` can read).
    ///   - format: The format buffers are emitted in. Determines channel count
    ///     and sample rate; the file is converted to this format once. Must be a
    ///     non-interleaved Float32 format (the shape the pipeline expects).
    ///   - chunkDuration: Duration of each emitted buffer. Defaults to 10 ms,
    ///     matching typical live-callback granularity.
    ///   - pacing: Delivery pacing. Defaults to real time.
    ///   - loop: When true, playback rewinds and continues instead of stopping
    ///     at end-of-file. Defaults to false.
    public init(
        fileURL: URL,
        format: AVAudioFormat,
        chunkDuration: TimeInterval = 0.01,
        pacing: Pacing = .realtime,
        loop: Bool = false
    ) {
        self.fileURL = fileURL
        self.outputFormat = format
        self.chunkDuration = chunkDuration
        self.pacing = pacing
        self.loop = loop
    }

    /// Whether the backing file exists and can be opened.
    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Starts playback, rewinding to the beginning of the file, and delivers
    /// buffers via `bufferCallback` until ``stop()`` is called (or end-of-file
    /// when `loop` is false).
    public func start(bufferCallback: @escaping AudioBufferCallback) async throws {
        let alreadyCapturing = state.withLock { $0.isCapturing }
        guard !alreadyCapturing else { return }

        let (channels, totalFrames) = try loadIfNeeded()

        let chunkFrames = max(1, Int(outputFormat.sampleRate * chunkDuration))
        let intervalNanos = UInt64((chunkDuration / pacing.speedFactor) * 1_000_000_000)

        let task = Task { [weak self] in
            guard let self else { return }
            let startNanos = DispatchTime.now().uptimeNanoseconds
            var chunkIndex: UInt64 = 0

            while !Task.isCancelled {
                guard let (buffer, time) = self.nextChunk(chunkFrames: chunkFrames) else {
                    break // end of file, not looping
                }
                bufferCallback(buffer, time)

                chunkIndex += 1
                let target = startNanos + chunkIndex * intervalNanos
                let now = DispatchTime.now().uptimeNanoseconds
                if target > now {
                    try? await Task.sleep(nanoseconds: target - now)
                }
            }
        }

        state.withLock {
            $0.channels = channels
            $0.totalFrames = totalFrames
            $0.readIndex = 0
            $0.emittedFrames = 0
            $0.pacingTask = task
            $0.isCapturing = true
        }
        logger.info("File playback started: \(self.fileURL.lastPathComponent) (\(totalFrames) frames)")
    }

    /// Stops playback and cancels the pacing task.
    public func stop() async {
        let task: Task<Void, Never>? = state.withLock {
            guard $0.isCapturing else { return nil }
            $0.isCapturing = false
            let existing = $0.pacingTask
            $0.pacingTask = nil
            return existing
        }
        task?.cancel()
        logger.info("File playback stopped")
    }

    // MARK: - Chunk vending

    /// Builds the next chunk buffer and advances the read position. Returns nil
    /// at end-of-file when not looping.
    private func nextChunk(chunkFrames: Int) -> (AVAudioPCMBuffer, AVAudioTime)? {
        state.withLock { st in
            guard let channels = st.channels, st.totalFrames > 0 else { return nil }

            if st.readIndex >= st.totalFrames {
                guard loop else { return nil }
                st.readIndex = 0
            }

            let remaining = st.totalFrames - st.readIndex
            let frames = min(chunkFrames, remaining)
            guard frames > 0 else { return nil }

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(frames)
            ), let dst = buffer.floatChannelData else { return nil }
            buffer.frameLength = AVAudioFrameCount(frames)

            let channelCount = Int(outputFormat.channelCount)
            for ch in 0 ..< channelCount {
                // Guard against a format/file channel mismatch by clamping.
                let source = channels[min(ch, channels.count - 1)]
                let dstChannel = dst[ch]
                source.withUnsafeBufferPointer { src in
                    for i in 0 ..< frames {
                        dstChannel[i] = src[st.readIndex + i]
                    }
                }
            }

            let time = AVAudioTime(sampleTime: st.emittedFrames, atRate: outputFormat.sampleRate)
            st.readIndex += frames
            st.emittedFrames += Int64(frames)
            return (buffer, time)
        }
    }

    // MARK: - File loading

    /// Loads and converts the file to the output format once, caching the result.
    private func loadIfNeeded() throws -> (channels: [[Float]], totalFrames: Int) {
        if let cached = state.withLock({ st -> (([[Float]], Int))? in
            guard let channels = st.channels else { return nil }
            return (channels, st.totalFrames)
        }) {
            return cached
        }

        let loaded = try loadFile()
        state.withLock {
            $0.channels = loaded.channels
            $0.totalFrames = loaded.totalFrames
        }
        return loaded
    }

    private func loadFile() throws -> (channels: [[Float]], totalFrames: Int) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw CaptureError.storageError(
                "Cannot open audio fixture \(fileURL.lastPathComponent): \(error.localizedDescription)"
            )
        }

        let fileFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount)
        else {
            throw CaptureError.storageError("Audio fixture \(fileURL.lastPathComponent) is empty")
        }
        try file.read(into: inputBuffer)

        let output = try convert(inputBuffer, from: fileFormat)
        let frames = Int(output.frameLength)
        guard frames > 0, let channelData = output.floatChannelData else {
            throw CaptureError.storageError("Audio fixture conversion produced no samples")
        }

        let channelCount = Int(outputFormat.channelCount)
        var channels = [[Float]](repeating: [], count: channelCount)
        for ch in 0 ..< channelCount {
            channels[ch] = Array(UnsafeBufferPointer(start: channelData[ch], count: frames))
        }
        return (channels, frames)
    }

    /// Converts the input buffer to ``outputFormat``, skipping conversion when
    /// the formats already match.
    private func convert(_ input: AVAudioPCMBuffer, from fileFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if fileFormat == outputFormat {
            return input
        }

        guard let converter = AVAudioConverter(from: fileFormat, to: outputFormat) else {
            throw CaptureError.configurationFailed(
                "Cannot convert fixture from \(fileFormat) to \(outputFormat)"
            )
        }

        let ratio = outputFormat.sampleRate / fileFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw CaptureError.storageError("Cannot allocate conversion buffer")
        }

        // The whole input buffer is fed in a single call; a reference-type box
        // tracks that without a mutable capture (the closure is @Sendable).
        final class FeedState: @unchecked Sendable { var consumed = false }
        let feed = FeedState()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if feed.consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            feed.consumed = true
            inputStatus.pointee = .haveData
            return input
        }

        if status == .error, let conversionError {
            throw CaptureError.configurationFailed("Fixture conversion failed: \(conversionError.localizedDescription)")
        }
        return output
    }
}
