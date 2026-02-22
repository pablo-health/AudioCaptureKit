import AVFoundation
import CoreAudio
import Crypto
import Foundation
import os

/// A composite capture session that combines microphone and system audio.
///
/// `CompositeCaptureSession` is the primary implementation of ``AudioCaptureSession``.
/// It coordinates a ``CoreAudioTapCapture`` (system audio, right channel) and an
/// ``AVFoundationMicCapture`` (microphone, left channel), mixing them into stereo
/// PCM and writing the result to an optionally encrypted WAV file.
///
/// ## State Machine
/// ```
/// idle -> configuring -> ready -> capturing <-> paused
///                                    |              |
///                                    v              v
///                                 stopping -> completed
///                                    |
///                                    v
///                                  failed
/// ```
public final class CompositeCaptureSession: @unchecked Sendable {
    struct SessionState {
        var state: CaptureState = .idle
        var delegate: (any AudioCaptureDelegate)?
        var configuration: CaptureConfiguration
        var currentLevels: AudioLevels = .zero
        var captureStartTime: Date?
        var pausedDuration: TimeInterval = 0
        var lastPauseTime: Date?
        var fileURL: URL?
        var diagnostics = CaptureSessionDiagnostics()
        /// Actual mic sample rate detected from the first callback (may differ from config).
        var detectedMicRate: Double?
    }

    let sessionState: UnfairLock<SessionState>

    let micCapture: AVFoundationMicCapture
    let systemCapture: CoreAudioTapCapture
    var stereoMixer: StereoMixer

    var fileWriter: EncryptedFileWriter?
    var micBuffer: AudioBufferManager?
    var systemBuffer: AudioBufferManager?

    var durationTimer: Task<Void, Never>?
    var processingTask: Task<Void, Never>?

    let logger = Logger(
        subsystem: "com.audiocapturekit",
        category: "CompositeCaptureSession"
    )

    /// Creates a new composite capture session.
    /// - Parameter configuration: Initial configuration. Can be updated via ``configure(_:)``.
    public init(configuration: CaptureConfiguration) {
        self.sessionState = UnfairLock(SessionState(configuration: configuration))
        self.micCapture = AVFoundationMicCapture(deviceID: configuration.micDeviceID)
        self.systemCapture = CoreAudioTapCapture()
        self.stereoMixer = StereoMixer(targetSampleRate: configuration.sampleRate)
    }

    func setState(_ newState: CaptureState) {
        let delegate: (any AudioCaptureDelegate)? = sessionState.withLock {
            $0.state = newState
            return $0.delegate
        }

        delegate?.captureSession(self, didChangeState: newState)
    }

    func setLevels(_ levels: AudioLevels) {
        let delegate: (any AudioCaptureDelegate)? = sessionState.withLock {
            $0.currentLevels = levels
            return $0.delegate
        }

        delegate?.captureSession(self, didUpdateLevels: levels)
    }

    func elapsedDuration() -> TimeInterval {
        sessionState.withLock { state in
            guard let startTime = state.captureStartTime else { return 0 }
            let totalElapsed = Date().timeIntervalSince(startTime)
            let currentPauseDuration: TimeInterval = if let pauseTime = state.lastPauseTime {
                Date().timeIntervalSince(pauseTime)
            } else {
                0
            }
            return totalElapsed - state.pausedDuration - currentPauseDuration
        }
    }
}

// MARK: - AudioCaptureSession

extension CompositeCaptureSession: AudioCaptureSession {
    public var state: CaptureState {
        sessionState.withLock { $0.state }
    }

    public var delegate: (any AudioCaptureDelegate)? {
        get { sessionState.withLock { $0.delegate } }
        set { sessionState.withLock { $0.delegate = newValue } }
    }

    public var configuration: CaptureConfiguration {
        sessionState.withLock { $0.configuration }
    }

    public var currentLevels: AudioLevels {
        sessionState.withLock { $0.currentLevels }
    }

    /// Live diagnostic counters for debugging the capture pipeline.
    public var diagnostics: CaptureSessionDiagnostics {
        sessionState.withLock { $0.diagnostics }
    }

    public func configure(_ configuration: CaptureConfiguration) throws {
        let currentState = sessionState.withLock { $0.state }
        guard case .idle = currentState else {
            throw CaptureError.configurationFailed(
                "Cannot configure while not idle"
            )
        }

        setState(.configuring)

        guard configuration.sampleRate > 0 else {
            setState(.failed(.configurationFailed("Invalid sample rate")))
            throw CaptureError.configurationFailed("Sample rate must be positive")
        }
        guard [16, 24, 32].contains(configuration.bitDepth) else {
            setState(.failed(.configurationFailed("Invalid bit depth")))
            throw CaptureError.configurationFailed("Bit depth must be 16, 24, or 32")
        }
        guard configuration.channels > 0, configuration.channels <= 2 else {
            setState(.failed(.configurationFailed("Invalid channel count")))
            throw CaptureError.configurationFailed("Channel count must be 1 or 2")
        }

        sessionState.withLock { $0.configuration = configuration }

        setState(.ready)
    }

    public func startCapture() async throws {
        let currentState = sessionState.withLock { $0.state }
        guard case .ready = currentState else {
            throw CaptureError.configurationFailed("Cannot start capture when not ready")
        }

        let config = configuration
        let outputRate = try await resolveOutputRate(config: config)

        try await prepareFileWriter(config: config, outputRate: outputRate)
        try await startMicCapture(config: config)
        await startSystemCapture(config: config)

        sessionState.withLock {
            $0.captureStartTime = Date()
            $0.pausedDuration = 0
        }
        setState(.capturing(duration: 0))

        startDurationTimer()
        startProcessingLoop()
    }

    public func pauseCapture() throws {
        let currentState = sessionState.withLock { $0.state }
        guard case .capturing = currentState else {
            throw CaptureError.configurationFailed("Cannot pause when not capturing")
        }

        sessionState.withLock { $0.lastPauseTime = Date() }
        let elapsed = elapsedDuration()
        setState(.paused(duration: elapsed))
    }

    public func resumeCapture() throws {
        let currentState = sessionState.withLock { $0.state }
        guard case .paused = currentState else {
            throw CaptureError.configurationFailed("Cannot resume when not paused")
        }

        sessionState.withLock { state in
            if let pauseTime = state.lastPauseTime {
                state.pausedDuration += Date().timeIntervalSince(pauseTime)
            }
            state.lastPauseTime = nil
        }
        let elapsed = elapsedDuration()
        setState(.capturing(duration: elapsed))
    }

    public func stopCapture() async throws -> RecordingResult {
        let currentState = sessionState.withLock { $0.state }
        switch currentState {
        case .capturing, .paused:
            break
        default:
            throw CaptureError.configurationFailed(
                "Cannot stop when not capturing or paused"
            )
        }

        setState(.stopping)

        await micCapture.stop()
        await systemCapture.stop()

        durationTimer?.cancel()
        durationTimer = nil
        processingTask?.cancel()
        processingTask = nil

        await processBuffers()

        return try await finalizeRecording()
    }

    // MARK: - Capture Setup Helpers

    /// Detects the actual mic sample rate (HFP probe) and configures the mixer.
    private func resolveOutputRate(config: CaptureConfiguration) async throws -> Double {
        var actualMicRate = config.sampleRate

        if config.enableMicCapture {
            actualMicRate = try await detectMicRate(config: config)
            logger.info("Mic actual rate after HFP negotiation: \(actualMicRate)Hz")
        }

        let outputRate = min(actualMicRate, config.sampleRate)
        logger.info("Output rate: \(outputRate)Hz")

        stereoMixer = StereoMixer(targetSampleRate: outputRate)
        sessionState.withLock { $0.detectedMicRate = actualMicRate }

        return outputRate
    }

    /// Creates ring buffers and opens the file writer with the confirmed rate.
    private func prepareFileWriter(
        config: CaptureConfiguration,
        outputRate: Double
    ) async throws {
        let bufferCapacity = Int(outputRate * 5)
        micBuffer = AudioBufferManager(capacity: bufferCapacity)
        systemBuffer = AudioBufferManager(capacity: bufferCapacity * 2)

        let fileName = "recording_\(UUID().uuidString)"
        let ext = config.encryptor != nil ? "enc.wav" : "wav"
        let fileURL = config.outputDirectory.appendingPathComponent("\(fileName).\(ext)")
        let writer = EncryptedFileWriter(fileURL: fileURL, encryptor: config.encryptor)
        fileWriter = writer
        sessionState.withLock { $0.fileURL = fileURL }

        let outputConfig = CaptureConfiguration(
            sampleRate: outputRate,
            bitDepth: config.bitDepth,
            channels: config.channels,
            encryptor: config.encryptor,
            outputDirectory: config.outputDirectory,
            maxDuration: config.maxDuration,
            micDeviceID: config.micDeviceID,
            enableMicCapture: config.enableMicCapture,
            enableSystemCapture: config.enableSystemCapture
        )

        do {
            try await writer.open(configuration: outputConfig)
        } catch {
            setState(.failed(.storageError("Failed to open file")))
            throw error
        }
    }

    /// Stops the probe session and starts the real mic capture.
    private func startMicCapture(config: CaptureConfiguration) async throws {
        guard config.enableMicCapture else {
            logger.info("Mic capture disabled by configuration")
            return
        }

        await micCapture.stop()
        do {
            try await micCapture.start { [weak self] buffer, _ in
                self?.handleMicBuffer(buffer)
            }
        } catch {
            setState(.failed(.deviceNotAvailable))
            throw CaptureError.deviceNotAvailable
        }
    }

    /// Starts system audio capture if enabled and available.
    private func startSystemCapture(config: CaptureConfiguration) async {
        guard config.enableSystemCapture, systemCapture.isAvailable else {
            if !config.enableSystemCapture {
                logger.info("System audio capture disabled by configuration")
            }
            return
        }

        do {
            try await systemCapture.start { [weak self] buffer, _ in
                self?.handleSystemBuffer(buffer)
            }
        } catch {
            logger.warning("System audio capture unavailable: \(error)")
            let delegate = sessionState.withLock { $0.delegate }
            delegate?.captureSession(
                self,
                didEncounterError: .configurationFailed(
                    "System audio unavailable: \(error.localizedDescription). "
                        + "Ensure this app is enabled in System Settings > "
                        + "Privacy & Security > Screen & System Audio Recording."
                )
            )
        }
    }
}
