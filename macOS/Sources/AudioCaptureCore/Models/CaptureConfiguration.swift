import Foundation

/// Encoding used for the per-channel sidecar files (see ``CaptureConfiguration/exportRawPCM``).
public enum SidecarAudioFormat: Sendable {
    /// Signed 16-bit little-endian PCM, no container. Lossless, but large
    /// (~288 MB mono / ~576 MB stereo for a 50-minute session).
    case rawPCM
    /// Streaming AAC-LC in a self-framing ADTS stream (`.aac`). ~12-24× smaller
    /// than raw PCM; lossy but transparent for transcription. Encodes during
    /// capture, so the stop-time sidecar is already compressed.
    case aacADTS
}

/// Configuration for an audio capture session.
public struct CaptureConfiguration: Sendable {
    /// Audio sample rate in Hz. Default is 48000.
    public let sampleRate: Double

    /// Bit depth for audio samples. Default is 16.
    public let bitDepth: Int

    /// Number of audio channels. Default is 2 (stereo).
    public let channels: Int

    /// Optional encryptor for encrypting audio data at rest.
    public let encryptor: (any CaptureEncryptor)?

    /// Directory where recorded files will be stored.
    public let outputDirectory: URL

    /// Optional maximum recording duration in seconds.
    public let maxDuration: TimeInterval?

    /// Optional specific microphone device ID to use instead of the system default.
    public let micDeviceID: String?

    /// Whether to capture microphone audio. Default is true.
    public let enableMicCapture: Bool

    /// Whether to capture system audio. Default is true.
    public let enableSystemCapture: Bool

    /// Determines how mic and system audio are combined into the output WAV.
    /// Default is ``MixingStrategy/blended`` to preserve existing behavior.
    public let mixingStrategy: MixingStrategy

    /// When true, writes PCM sidecar files alongside the WAV:
    /// - `{name}_mic.pcm`    — mono mic, signed 16-bit LE, no header
    /// - `{name}_system.pcm` — interleaved stereo system audio, signed 16-bit LE, no header
    ///
    /// When an ``encryptor`` is set, sidecar files use `.enc.pcm` extension and the
    /// same length-prefixed encrypted chunk format as the main WAV file (no plaintext on disk).
    /// Default: false.
    public let exportRawPCM: Bool

    /// Encoding for the sidecar files when ``exportRawPCM`` is true.
    /// Default ``SidecarAudioFormat/rawPCM`` preserves existing behavior; use
    /// ``SidecarAudioFormat/aacADTS`` to compress during capture and produce
    /// small `.aac` sidecars instead of hundreds of MB of raw PCM.
    public let sidecarFormat: SidecarAudioFormat

    /// Target bitrate (bits/sec) for ``SidecarAudioFormat/aacADTS`` sidecars.
    /// 64 kbps is transparent for speech transcription. Ignored for raw PCM.
    public let sidecarAACBitRate: Int

    /// Duration in seconds of the internal ring buffer. Larger values tolerate
    /// longer I/O stalls before dropping samples. Default is 30 seconds.
    public let bufferDurationSeconds: TimeInterval

    public init(
        sampleRate: Double = 48000,
        bitDepth: Int = 16,
        channels: Int = 2,
        encryptor: (any CaptureEncryptor)? = nil,
        outputDirectory: URL,
        maxDuration: TimeInterval? = nil,
        micDeviceID: String? = nil,
        enableMicCapture: Bool = true,
        enableSystemCapture: Bool = true,
        mixingStrategy: MixingStrategy = .blended,
        exportRawPCM: Bool = false,
        sidecarFormat: SidecarAudioFormat = .rawPCM,
        sidecarAACBitRate: Int = 64000,
        bufferDurationSeconds: TimeInterval = 30
    ) {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.encryptor = encryptor
        self.outputDirectory = outputDirectory
        self.maxDuration = maxDuration
        self.micDeviceID = micDeviceID
        self.enableMicCapture = enableMicCapture
        self.enableSystemCapture = enableSystemCapture
        self.mixingStrategy = mixingStrategy
        self.exportRawPCM = exportRawPCM
        self.sidecarFormat = sidecarFormat
        self.sidecarAACBitRate = sidecarAACBitRate
        self.bufferDurationSeconds = bufferDurationSeconds
    }
}
