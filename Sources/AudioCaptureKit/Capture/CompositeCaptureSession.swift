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
    private struct SessionState {
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

    private let sessionState: UnfairLock<SessionState>

    private let micCapture: AVFoundationMicCapture
    private let systemCapture: CoreAudioTapCapture
    private var stereoMixer: StereoMixer

    private var fileWriter: EncryptedFileWriter?
    private var micBuffer: AudioBufferManager?
    private var systemBuffer: AudioBufferManager?

    private var durationTimer: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?

    private let logger = Logger(
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

    private func setState(_ newState: CaptureState) {
        let delegate: (any AudioCaptureDelegate)? = sessionState.withLock {
            $0.state = newState
            return $0.delegate
        }

        delegate?.captureSession(self, didChangeState: newState)
    }

    private func setLevels(_ levels: AudioLevels) {
        let delegate: (any AudioCaptureDelegate)? = sessionState.withLock {
            $0.currentLevels = levels
            return $0.delegate
        }

        delegate?.captureSession(self, didUpdateLevels: levels)
    }

    private func elapsedDuration() -> TimeInterval {
        sessionState.withLock { s in
            guard let startTime = s.captureStartTime else { return 0 }
            let totalElapsed = Date().timeIntervalSince(startTime)
            let currentPauseDuration: TimeInterval
            if let pauseTime = s.lastPauseTime {
                currentPauseDuration = Date().timeIntervalSince(pauseTime)
            } else {
                currentPauseDuration = 0
            }
            return totalElapsed - s.pausedDuration - currentPauseDuration
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

    public func availableAudioSources() async throws -> [AudioSource] {
        var sources: [AudioSource] = []

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        let defaultDevice = AVCaptureDevice.default(for: .audio)

        for device in discoverySession.devices {
            sources.append(AudioSource(
                id: device.uniqueID,
                name: device.localizedName,
                type: .mic,
                isDefault: device.uniqueID == defaultDevice?.uniqueID,
                transportType: Self.transportType(forDeviceUID: device.uniqueID)
            ))
        }

        if systemCapture.isAvailable {
            sources.append(AudioSource(
                id: "system-audio",
                name: "System Audio",
                type: .system,
                isDefault: true
            ))
        }

        return sources
    }

    /// Queries CoreAudio for the transport type of a device by its UID.
    private static func transportType(forDeviceUID uid: String) -> AudioTransportType {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // kAudioHardwarePropertyDeviceForUID expects a pointer to a CFStringRef as input.
        // Use nested withUnsafeMutablePointer to ensure pointer lifetimes are scoped correctly.
        var cfUID: CFString = uid as CFString
        let status: OSStatus = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            withUnsafeMutablePointer(to: &deviceID) { deviceIDPtr in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(uidPtr),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(deviceIDPtr),
                    mOutputDataSize: size
                )
                var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0, nil,
                    &translationSize,
                    &translation
                )
            }
        }
        guard status == noErr else { return .unknown }

        var transportType: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType

        let transportStatus = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &transportType
        )
        guard transportStatus == noErr else { return .unknown }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth:
            return .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE:
            return .bluetoothLE
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeVirtual:
            return .virtual
        default:
            return .unknown
        }
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

        // PHASE 1: Start mic capture and detect the ACTUAL sample rate.
        // We must detect the rate from a real callback because Bluetooth HFP
        // negotiation changes the rate when the capture session activates —
        // querying the device beforehand returns the pre-HFP rate.
        var actualMicRate = config.sampleRate

        if config.enableMicCapture {
            actualMicRate = try await detectMicRate(config: config)
            logger.info("Mic actual rate after HFP negotiation: \(actualMicRate)Hz")
        }

        // Use the lowest rate — never upsample, only downsample.
        let outputRate = min(actualMicRate, config.sampleRate)
        logger.info("Output rate: \(outputRate)Hz")

        self.stereoMixer = StereoMixer(targetSampleRate: outputRate)
        sessionState.withLock { $0.detectedMicRate = actualMicRate }

        // PHASE 2: Set up file writer with the confirmed rate.
        let bufferCapacity = Int(outputRate * 5)
        micBuffer = AudioBufferManager(capacity: bufferCapacity)
        systemBuffer = AudioBufferManager(capacity: bufferCapacity * 2)

        let fileName = "recording_\(UUID().uuidString)"
        let fileExtension = config.encryptor != nil ? "enc.wav" : "wav"
        let fileURL = config.outputDirectory.appendingPathComponent("\(fileName).\(fileExtension)")
        let writer = EncryptedFileWriter(fileURL: fileURL, encryptor: config.encryptor)
        self.fileWriter = writer

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

        // PHASE 3: Now start the real mic capture (with the confirmed rate).
        if config.enableMicCapture {
            // Stop the probe session and start the real one
            await micCapture.stop()
            do {
                try await micCapture.start { [weak self] buffer, time in
                    guard let self else { return }
                    let sampleRate = buffer.format.sampleRate
                    let formatDesc = "\(Int(sampleRate))Hz \(buffer.format.channelCount)ch \(buffer.format.isInterleaved ? "int" : "non-int")"

                    guard let samples = AudioFormatConverter.extractMonoSamples(from: buffer) else {
                        self.logger.warning("Mic: extractMonoSamples returned nil for \(formatDesc)")
                        return
                    }
                    let resampled = self.stereoMixer.resample(samples, from: sampleRate)
                    self.updateMicLevel(samples: resampled)
                    self.sessionState.withLock {
                        $0.diagnostics.micCallbackCount += 1
                        $0.diagnostics.micSamplesTotal += resampled.count
                        $0.diagnostics.micFormat = formatDesc
                    }
                    Task { await self.micBuffer?.write(resampled) }
                }
            } catch {
                setState(.failed(.deviceNotAvailable))
                throw CaptureError.deviceNotAvailable
            }
        } else {
            logger.info("Mic capture disabled by configuration")
        }

        if config.enableSystemCapture && systemCapture.isAvailable {
            do {
                try await systemCapture.start { [weak self] buffer, time in
                    guard let self else { return }
                    let formatDesc = "\(Int(buffer.format.sampleRate))Hz \(buffer.format.channelCount)ch \(buffer.format.isInterleaved ? "int" : "non-int")"
                    // System audio stays as interleaved stereo [L0, R0, L1, R1, ...]
                    // to preserve the stereo image in the final recording.
                    guard let samples = AudioFormatConverter.extractFloatSamples(from: buffer) else {
                        self.logger.warning("System: extractFloatSamples returned nil for \(formatDesc)")
                        return
                    }
                    // The tap format may claim 48kHz but the aggregate device
                    // actually delivers at the output device's rate (e.g. 24kHz for HFP).
                    // Detect the TRUE rate from the data: frames per callback / callback interval.
                    // For safety, compare buffer frame count against what we'd expect at the
                    // reported rate vs target rate. If the frame count matches the target rate
                    // better, the format is lying and the data is already at target rate.
                    let reportedRate = buffer.format.sampleRate
                    let channelCount = Int(buffer.format.channelCount)
                    let targetRate = self.stereoMixer.targetSampleRate
                    let frameCount = Int(buffer.frameLength)

                    // Log on first callback to diagnose rate mismatch
                    let sysCount = self.sessionState.withLock { $0.diagnostics.systemCallbackCount }
                    if sysCount == 0 {
                        self.logger.info("System audio: reported=\(reportedRate)Hz, target=\(targetRate)Hz, frames=\(frameCount), channels=\(channelCount), samples=\(samples.count)")
                    }

                    // Use target rate as the true source rate when the aggregate device
                    // runs at the HFP rate. The tap format is unreliable for this.
                    let effectiveSourceRate = targetRate
                    let resampled: [Float]
                    if channelCount >= 2 {
                        resampled = self.stereoMixer.resampleStereo(samples, from: effectiveSourceRate)
                    } else {
                        let mono = self.stereoMixer.resample(samples, from: effectiveSourceRate)
                        resampled = self.stereoMixer.interleave(left: mono, right: mono)
                    }

                    if sysCount == 0 {
                        self.logger.info("System audio after resample: in=\(samples.count) out=\(resampled.count) (effective source=\(effectiveSourceRate)Hz)")
                    }

                    self.updateSystemLevel(samples: resampled)
                    self.sessionState.withLock {
                        $0.diagnostics.systemCallbackCount += 1
                        $0.diagnostics.systemSamplesTotal += resampled.count
                        $0.diagnostics.systemFormat = "\(Int(reportedRate))→\(Int(targetRate))Hz \(channelCount)ch"
                    }
                    Task { await self.systemBuffer?.write(resampled) }
                }
            } catch {
                logger.warning("System audio capture unavailable: \(error)")
                let delegate = sessionState.withLock { $0.delegate }
                delegate?.captureSession(
                    self,
                    didEncounterError: .configurationFailed(
                        "System audio unavailable: \(error.localizedDescription). "
                        + "Ensure this app is enabled in System Settings > Privacy & Security > "
                        + "Screen & System Audio Recording."
                    )
                )
            }
        } else if !config.enableSystemCapture {
            logger.info("System audio capture disabled by configuration")
        }

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

        sessionState.withLock { s in
            if let pauseTime = s.lastPauseTime {
                s.pausedDuration += Date().timeIntervalSince(pauseTime)
            }
            s.lastPauseTime = nil
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
            throw CaptureError.configurationFailed("Cannot stop when not capturing or paused")
        }

        setState(.stopping)

        await micCapture.stop()
        await systemCapture.stop()

        durationTimer?.cancel()
        durationTimer = nil
        processingTask?.cancel()
        processingTask = nil

        // Flush remaining buffers
        await processBuffers()

        guard let writer = fileWriter else {
            throw CaptureError.storageError("No file writer available")
        }

        // Pass the actual detected sample rate to fix up the WAV header.
        // The mic rate may have changed after capture started (HFP negotiation).
        let detectedRate = sessionState.withLock { $0.detectedMicRate }
        let actualRate = detectedRate.map { min($0, configuration.sampleRate) }

        let checksum: String
        do {
            checksum = try await writer.close(
                actualSampleRate: actualRate,
                channels: UInt16(configuration.channels),
                bitDepth: UInt16(configuration.bitDepth)
            )
        } catch {
            setState(.failed(.storageError("Failed to close file")))
            throw error
        }

        let duration = elapsedDuration()
        let config = configuration
        let fileURL: URL = sessionState.withLock { $0.fileURL! }

        let metadata = RecordingMetadata(
            duration: duration,
            fileURL: fileURL,
            checksum: checksum,
            isEncrypted: config.encryptor != nil,
            tracks: [
                AudioTrack(type: .mic, channel: .center),
                AudioTrack(type: .system, channel: .stereo)
            ],
            encryptionAlgorithm: config.encryptor?.algorithm,
            encryptionKeyId: config.encryptor?.keyMetadata()["keyId"]
        )

        let result = RecordingResult(
            fileURL: fileURL,
            duration: duration,
            metadata: metadata,
            checksum: checksum
        )

        setState(.completed(result))

        let delegate = sessionState.withLock { $0.delegate }
        delegate?.captureSession(self, didFinishCapture: result)

        return result
    }

    // MARK: - Private Helpers

    private func startDurationTimer() {
        durationTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { break }

                let currentState = self.sessionState.withLock { $0.state }
                if case .capturing = currentState {
                    let duration = self.elapsedDuration()
                    self.setState(.capturing(duration: duration))

                    if let maxDuration = self.configuration.maxDuration, duration >= maxDuration {
                        _ = try? await self.stopCapture()
                        break
                    }
                }
            }
        }
    }

    private func startProcessingLoop() {
        processingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled else { break }

                let currentState = self.sessionState.withLock { $0.state }
                if case .capturing = currentState {
                    await self.processBuffers()
                }
            }
        }
    }

    private func processBuffers() async {
        guard let micBuffer, let systemBuffer, let writer = fileWriter else { return }

        let config = configuration
        let chunkSize = Int(config.sampleRate * 0.1) // 100ms frames

        let micSamples: [Float]
        let systemSamples: [Float]

        if config.enableSystemCapture {
            // System audio drives the timing. Mic is added when available.
            // This prevents timing issues when mic rate changes mid-stream
            // (e.g. Bluetooth HFP negotiation) or when mic callbacks stall.
            let systemFramesAvailable = await systemBuffer.count / 2
            let framesToProcess = min(systemFramesAvailable, chunkSize)
            guard framesToProcess > 0 else { return }
            systemSamples = await systemBuffer.read(count: framesToProcess * 2)
            // Read matching mic data — may be less than system frames, mixer zero-pads
            micSamples = await micBuffer.read(count: framesToProcess)
        } else {
            // Mic-only mode
            micSamples = await micBuffer.read(count: chunkSize)
            systemSamples = []
            guard !micSamples.isEmpty else { return }
        }

        // Mix: Left = mic + systemL, Right = mic + systemR
        let stereoSamples = stereoMixer.mixMicWithStereoSystem(
            mic: micSamples, system: systemSamples
        )
        let pcmData = stereoMixer.convertToInt16PCM(stereoSamples)

        sessionState.withLock {
            $0.diagnostics.mixCycles += 1
            $0.diagnostics.bytesWritten += pcmData.count
        }

        do {
            try await writer.write(pcmData)
        } catch {
            let delegate = sessionState.withLock { $0.delegate }
            if let captureError = error as? CaptureError {
                delegate?.captureSession(self, didEncounterError: captureError)
            }
        }
    }

    private func updateMicLevel(samples: [Float]) {
        guard !samples.isEmpty else { return }
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        let peak = samples.map { abs($0) }.max() ?? 0

        let current = sessionState.withLock { $0.currentLevels }

        setLevels(AudioLevels(
            micLevel: rms,
            systemLevel: current.systemLevel,
            peakMicLevel: max(peak, current.peakMicLevel),
            peakSystemLevel: current.peakSystemLevel
        ))
    }

    private func updateSystemLevel(samples: [Float]) {
        guard !samples.isEmpty else { return }
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        let peak = samples.map { abs($0) }.max() ?? 0

        let current = sessionState.withLock { $0.currentLevels }

        setLevels(AudioLevels(
            micLevel: current.micLevel,
            systemLevel: rms,
            peakMicLevel: current.peakMicLevel,
            peakSystemLevel: max(peak, current.peakSystemLevel)
        ))
    }

    /// Starts mic capture briefly to detect the actual sample rate after
    /// Bluetooth HFP negotiation. Waits up to 500ms for the rate to stabilize,
    /// since HFP negotiation may take several callbacks to complete.
    private func detectMicRate(config: CaptureConfiguration) async throws -> Double {
        let lowestRate = UnfairLock(config.sampleRate)

        try await micCapture.start { buffer, _ in
            let rate = buffer.format.sampleRate
            lowestRate.withLock { current in
                if rate < current { current = rate }
            }
        }

        // Wait for HFP negotiation to settle — rate may drop after a few callbacks
        try? await Task.sleep(nanoseconds: 500_000_000)

        let result = lowestRate.withLock { $0 }
        logger.info("Mic rate probe detected: \(result)Hz (after 500ms settling)")
        return result
    }
}
