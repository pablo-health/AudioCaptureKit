import AVFoundation
import Foundation
import os

/// Streaming AAC encoder: converts captured Float32 PCM chunks to AAC-LC and
/// emits self-framing **ADTS** frames as they are produced.
///
/// ## Why ADTS, not an `.m4a`/MPEG-4 container
/// An `.m4a` file writes its `moov` atom at *close* (a seek-back finalize), which
/// makes it impossible to (a) interpose the per-chunk encryption the capture
/// sidecar path requires or (b) avoid leaving plaintext on disk. ADTS is
/// self-framing — every AAC packet is prefixed with a 7-byte header that carries
/// its own length — so the stream can be written incrementally during capture,
/// finalized with ~0 latency at stop, and each frame handed to the same
/// length-prefixed encrypted-chunk writer the raw-PCM sidecars use. AssemblyAI
/// accepts an ADTS `.aac` stream identically to `.m4a`.
///
/// The encoder is single-producer: feed it PCM on one serial queue and it emits
/// ADTS frames on that same queue via ``onFrame``. It is not safe to call
/// ``encode(_:)``/``finish()`` concurrently. `@unchecked Sendable` reflects that
/// serialized-access contract (the owning ``CompositeCaptureSession`` drives it
/// only from its PCM I/O queue), matching that type's own concurrency posture.
final class AACStreamEncoder: @unchecked Sendable {
    /// Called with each finished ADTS frame (header + AAC payload). The caller
    /// owns persistence (plaintext append or encrypted length-prefixed chunk).
    typealias FrameSink = (Data) -> Void

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let sampleRate: Double
    private let channels: Int
    private let onFrame: FrameSink
    private let logger: Logger

    /// Set once at `finish()`: the converter's input block then reports
    /// end-of-stream so the last partial frame is flushed.
    private var pendingInputExhausted = false

    /// Whether the current `drain` cycle has already handed its one input
    /// buffer to the converter. An instance property (not a captured local) so
    /// the converter's `@Sendable` input block can flip it without tripping the
    /// concurrency checker; access stays serialized on the PCM I/O queue.
    private var inputProvidedThisCycle = false

    /// Builds an encoder for `channels`-channel Float32 PCM at `sampleRate`.
    /// Returns nil if AVFoundation can't build the AAC converter (unsupported
    /// rate/channel combo) — the caller then falls back to raw PCM.
    init?(
        sampleRate: Double,
        channels: Int,
        bitRate: Int,
        logger: Logger,
        onFrame: @escaping FrameSink
    ) {
        guard let inFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            logger.error("AACStreamEncoder: could not build Float32 input format (\(channels)ch @ \(sampleRate)Hz)")
            return nil
        }

        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ]
        guard let outFormat = AVAudioFormat(settings: outSettings),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else {
            logger.error("AACStreamEncoder: could not build AAC converter (\(channels)ch @ \(sampleRate)Hz)")
            return nil
        }

        self.converter = converter
        self.inputFormat = inFormat
        self.sampleRate = sampleRate
        self.channels = channels
        self.onFrame = onFrame
        self.logger = logger
    }

    /// Encodes one chunk of PCM. `samples` is interleaved when `channels > 1`
    /// (the layout the capture graph already produces: mono mic, interleaved
    /// stereo system), matching ``AudioCaptureKit``'s sidecar convention.
    func encode(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let frameCount = samples.count / channels
        guard frameCount > 0 else { return }

        guard let inputBuffer = makeInputBuffer(from: samples, frameCount: frameCount) else { return }
        drain(feeding: inputBuffer)
    }

    /// Flushes the converter's internal buffer and emits any trailing frames.
    /// Call exactly once at stop; the encoder is unusable afterwards.
    func finish() {
        pendingInputExhausted = true
        drain(feeding: nil)
    }

    // MARK: - Internals

    /// Copies interleaved Float samples into a non-interleaved input buffer,
    /// deinterleaving per channel (trivial for mono).
    private func makeInputBuffer(from samples: [Float], frameCount: Int) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = buffer.floatChannelData else { return nil }
        for ch in 0 ..< channels {
            let dst = channelData[ch]
            var frame = 0
            var src = ch
            while frame < frameCount {
                dst[frame] = samples[src]
                frame += 1
                src += channels
            }
        }
        return buffer
    }

    /// Pulls compressed packets out of the converter until it starves (needs
    /// more input) or, when finishing, until it reports end-of-stream.
    private func drain(feeding input: AVAudioPCMBuffer?) {
        inputProvidedThisCycle = false
        let output = AVAudioCompressedBuffer(
            format: converter.outputFormat,
            packetCapacity: 8,
            maximumPacketSize: converter.maximumOutputPacketSize
        )

        while true {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, statusPtr in
                if self.pendingInputExhausted {
                    statusPtr.pointee = .endOfStream
                    return nil
                }
                if self.inputProvidedThisCycle {
                    // Converter wants a second packet this cycle but we only have
                    // the one chunk — starve it so it returns what it has.
                    statusPtr.pointee = .noDataNow
                    return nil
                }
                self.inputProvidedThisCycle = true
                statusPtr.pointee = .haveData
                return input
            }

            // Always drain the buffer first: `.inputRanDry`/`.endOfStream` can
            // still carry packets the converter produced before it starved, and
            // dropping them truncates the stream.
            if output.packetCount > 0 { emitFrames(from: output) }

            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return
            case .error:
                if let conversionError { logger.error("AACStreamEncoder convert error: \(conversionError)") }
                return
            @unknown default:
                return
            }
        }
    }

    /// Splits a compressed buffer into individual AAC packets, prepends an ADTS
    /// header to each, and hands the finished frame to the sink.
    private func emitFrames(from output: AVAudioCompressedBuffer) {
        let packetCount = Int(output.packetCount)
        guard packetCount > 0 else { return }
        let base = output.data.assumingMemoryBound(to: UInt8.self)

        var offset = 0
        for i in 0 ..< packetCount {
            let byteSize = if let descriptions = output.packetDescriptions {
                Int(descriptions[i].mDataByteSize)
            } else {
                Int(output.byteLength)
            }
            guard byteSize > 0 else { continue }

            var frame = Self.adtsHeader(payloadLength: byteSize, sampleRate: sampleRate, channels: channels)
            frame.append(UnsafeBufferPointer(start: base + offset, count: byteSize))
            onFrame(frame)
            offset += byteSize
        }
    }

    /// Builds a 7-byte ADTS header (no CRC) for one AAC-LC frame.
    /// See ISO/IEC 14496-3 / the ADTS spec.
    static func adtsHeader(payloadLength: Int, sampleRate: Double, channels: Int) -> Data {
        let frameLength = payloadLength + 7
        let profile = 1 // AAC-LC (audio object type 2 → profile field = 2 - 1)
        let freqIndex = samplingFrequencyIndex(for: sampleRate)
        let chanConfig = channels

        var header = [UInt8](repeating: 0, count: 7)
        header[0] = 0xFF // syncword high
        header[1] = 0xF1 // syncword low, MPEG-4, layer 0, no CRC
        header[2] = UInt8((profile << 6) | (freqIndex << 2) | ((chanConfig >> 2) & 0x1))
        header[3] = UInt8(((chanConfig & 0x3) << 6) | ((frameLength >> 11) & 0x3))
        header[4] = UInt8((frameLength >> 3) & 0xFF)
        header[5] = UInt8(((frameLength & 0x7) << 5) | 0x1F) // frame length low + buffer fullness high
        header[6] = 0xFC // buffer fullness low + 0 frames-1
        return Data(header)
    }

    /// ADTS sampling-frequency index table (ISO/IEC 14496-3 Table 1.16).
    private static func samplingFrequencyIndex(for sampleRate: Double) -> Int {
        let table: [Double: Int] = [
            96000: 0, 88200: 1, 64000: 2, 48000: 3, 44100: 4, 32000: 5,
            24000: 6, 22050: 7, 16000: 8, 12000: 9, 11025: 10, 8000: 11, 7350: 12,
        ]
        return table[sampleRate.rounded()] ?? 3 // default 48 kHz
    }
}
