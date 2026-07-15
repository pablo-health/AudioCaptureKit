import AVFoundation
import Foundation
import os

/// An ``AudioCaptureProvider`` that synthesizes a deterministic tone bed with
/// periodic marker bursts, instead of playing back a fixture file.
///
/// Unlike ``FilePlayerCaptureSource`` (which loops a short recorded clip), this
/// source generates every sample analytically from its frame index — no file
/// I/O, no RNG, no loop seam. That determinism is what makes it useful for the
/// capture soak: every marker's frequency and position is known in advance, so
/// a test can read the finalized recording back and prove the capture pipeline
/// preserved both channel separation (no mic/system bleed) and timing (no
/// drift or loss across a long real-time run).
///
/// The signal is a continuous ``MarkerTone/baseFrequency`` tone with a
/// ``MarkerTone/markerFrequency`` burst added on top once every
/// ``MarkerTone/markerPeriod`` seconds, starting at ``MarkerTone/markerOffset``.
/// Giving the mic and system sources different base/marker frequency pairs
/// (and an offset between their marker schedules) means a marker detected on
/// the wrong channel, or at the wrong time, unambiguously points at a
/// capture-pipeline bug rather than a coincidence in the fixture.
///
/// ## Restartability
/// Like ``FilePlayerCaptureSource``, each ``start(bufferCallback:)`` resets the
/// internal frame clock to zero, so a probe/start cycle doesn't skew the
/// marker schedule.
public final class SignalGeneratorCaptureSource: AudioCaptureProvider, @unchecked Sendable {
    /// Describes a continuous tone bed with a periodic marker burst added on top.
    public struct MarkerTone: Sendable {
        /// Frequency of the continuous tone bed, in Hz.
        public let baseFrequency: Double
        /// Frequency of the periodic marker burst, in Hz.
        public let markerFrequency: Double
        /// Seconds between the start of one marker burst and the next.
        public let markerPeriod: TimeInterval
        /// Seconds after source-time zero before the first marker burst starts.
        public let markerOffset: TimeInterval
        /// Duration of each marker burst, in seconds.
        public let markerDuration: TimeInterval

        public init(
            baseFrequency: Double,
            markerFrequency: Double,
            markerPeriod: TimeInterval,
            markerOffset: TimeInterval = 0,
            markerDuration: TimeInterval = 1.0
        ) {
            self.baseFrequency = baseFrequency
            self.markerFrequency = markerFrequency
            self.markerPeriod = markerPeriod
            self.markerOffset = markerOffset
            self.markerDuration = markerDuration
        }

        /// Whether a marker burst is sounding at `sourceTime` (seconds since start).
        func isMarkerActive(at sourceTime: TimeInterval) -> Bool {
            guard sourceTime >= markerOffset else { return false }
            let sincePhaseStart = (sourceTime - markerOffset).truncatingRemainder(dividingBy: markerPeriod)
            return sincePhaseStart < markerDuration
        }
    }

    private struct State {
        var emittedFrames: Int64 = 0
        var pacingTask: Task<Void, Never>?
        var isCapturing = false
    }

    private let outputFormat: AVAudioFormat
    private let tone: MarkerTone
    private let baseAmplitude: Float
    private let markerAmplitude: Float
    private let chunkDuration: TimeInterval

    private let state = UnfairLock(State())

    private let logger = Logger(
        subsystem: "com.audiocapturekit",
        category: "SignalGeneratorCaptureSource"
    )

    /// Creates a synthetic signal source.
    ///
    /// - Parameters:
    ///   - format: The format buffers are emitted in (channel count + sample
    ///     rate). Every channel carries the same tone bed.
    ///   - tone: The base/marker frequency pair and marker schedule.
    ///   - baseAmplitude: Amplitude of the continuous tone, in [-1, 1]. Defaults to 0.4.
    ///   - markerAmplitude: Amplitude added during a marker burst. Defaults to
    ///     0.3 — summed with `baseAmplitude` this stays comfortably under full
    ///     scale, avoiding clipping that would smear the marker's frequency
    ///     content with harmonics.
    ///   - chunkDuration: Duration of each emitted buffer. Defaults to 10 ms,
    ///     matching typical live-callback granularity.
    public init(
        format: AVAudioFormat,
        tone: MarkerTone,
        baseAmplitude: Float = 0.4,
        markerAmplitude: Float = 0.3,
        chunkDuration: TimeInterval = 0.01
    ) {
        self.outputFormat = format
        self.tone = tone
        self.baseAmplitude = baseAmplitude
        self.markerAmplitude = markerAmplitude
        self.chunkDuration = chunkDuration
    }

    /// Always available — there's no hardware or file dependency to fail.
    public var isAvailable: Bool {
        true
    }

    /// Starts generating, resetting the frame clock to zero, and delivers
    /// buffers via `bufferCallback` in real time until ``stop()`` is called.
    public func start(bufferCallback: @escaping AudioBufferCallback) async throws {
        let alreadyCapturing = state.withLock { $0.isCapturing }
        guard !alreadyCapturing else { return }

        let chunkFrames = max(1, Int(outputFormat.sampleRate * chunkDuration))
        let intervalNanos = UInt64(chunkDuration * 1_000_000_000)

        let task = Task { [weak self] in
            guard let self else { return }
            let startNanos = DispatchTime.now().uptimeNanoseconds
            var chunkIndex: UInt64 = 0

            while !Task.isCancelled {
                guard let (buffer, time) = self.nextChunk(chunkFrames: chunkFrames) else { break }
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
            $0.emittedFrames = 0
            $0.pacingTask = task
            $0.isCapturing = true
        }
        logger.info(
            "Signal generator started: base=\(self.tone.baseFrequency)Hz marker=\(self.tone.markerFrequency)Hz"
        )
    }

    /// Stops generating and cancels the pacing task.
    public func stop() async {
        let task: Task<Void, Never>? = state.withLock {
            guard $0.isCapturing else { return nil }
            $0.isCapturing = false
            let existing = $0.pacingTask
            $0.pacingTask = nil
            return existing
        }
        task?.cancel()
        logger.info("Signal generator stopped")
    }

    // MARK: - Sample synthesis

    /// Builds the next chunk buffer and advances the frame clock.
    private func nextChunk(chunkFrames: Int) -> (AVAudioPCMBuffer, AVAudioTime)? {
        state.withLock { st in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(chunkFrames)
            ), let dst = buffer.floatChannelData else { return nil }
            buffer.frameLength = AVAudioFrameCount(chunkFrames)

            let startFrame = st.emittedFrames
            let channelCount = Int(outputFormat.channelCount)
            for ch in 0 ..< channelCount {
                let dstChannel = dst[ch]
                for i in 0 ..< chunkFrames {
                    dstChannel[i] = sample(atFrame: startFrame + Int64(i))
                }
            }

            let time = AVAudioTime(sampleTime: st.emittedFrames, atRate: outputFormat.sampleRate)
            st.emittedFrames += Int64(chunkFrames)
            return (buffer, time)
        }
    }

    /// The synthesized sample at a given frame index — deterministic, no RNG.
    private func sample(atFrame frame: Int64) -> Float {
        let sourceTime = Double(frame) / outputFormat.sampleRate
        var value = Float(sin(2.0 * .pi * tone.baseFrequency * sourceTime)) * baseAmplitude
        if tone.isMarkerActive(at: sourceTime) {
            value += Float(sin(2.0 * .pi * tone.markerFrequency * sourceTime)) * markerAmplitude
        }
        return value
    }
}
