import AVFoundation
import Foundation
import os

// MARK: - Audio Processing, Timers & Buffer Callbacks

extension CompositeCaptureSession {
    func startDurationTimer() {
        durationTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { break }

                let currentState = self.sessionState.withLock { $0.state }
                if case .capturing = currentState {
                    let duration = self.elapsedDuration()
                    self.setState(.capturing(duration: duration))

                    if let maxDuration = self.configuration.maxDuration,
                       duration >= maxDuration {
                        _ = try? await self.stopCapture()
                        break
                    }
                }
            }
        }
    }

    func startProcessingLoop() {
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

    func processBuffers() async {
        guard let micBuffer, let systemBuffer, let writer = fileWriter else { return }

        let config = configuration
        let chunkSize = Int(config.sampleRate * 0.1) // 100ms frames

        let micSamples: [Float]
        let systemSamples: [Float]

        if config.enableSystemCapture {
            let systemFramesAvailable = await systemBuffer.count / 2
            let framesToProcess = min(systemFramesAvailable, chunkSize)
            guard framesToProcess > 0 else { return }
            systemSamples = await systemBuffer.read(count: framesToProcess * 2)
            micSamples = await micBuffer.read(count: framesToProcess)
        } else {
            micSamples = await micBuffer.read(count: chunkSize)
            systemSamples = []
            guard !micSamples.isEmpty else { return }
        }

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

    // MARK: - Audio Buffer Callbacks

    /// Processes a single mic audio buffer from AVFoundation.
    func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        let sampleRate = buffer.format.sampleRate
        let formatDesc =
            "\(Int(sampleRate))Hz \(buffer.format.channelCount)ch "
            + "\(buffer.format.isInterleaved ? "int" : "non-int")"

        guard let samples = AudioFormatConverter.extractMonoSamples(from: buffer) else {
            logger.warning("Mic: extractMonoSamples returned nil for \(formatDesc)")
            return
        }
        let resampled = stereoMixer.resample(samples, from: sampleRate)
        updateMicLevel(samples: resampled)
        sessionState.withLock {
            $0.diagnostics.micCallbackCount += 1
            $0.diagnostics.micSamplesTotal += resampled.count
            $0.diagnostics.micFormat = formatDesc
        }
        Task { await micBuffer?.write(resampled) }
    }

    /// Processes a single system audio buffer from Core Audio tap.
    func handleSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        let reportedRate = buffer.format.sampleRate
        let channelCount = Int(buffer.format.channelCount)
        let targetRate = stereoMixer.targetSampleRate
        let formatDesc =
            "\(Int(reportedRate))Hz \(channelCount)ch "
            + "\(buffer.format.isInterleaved ? "int" : "non-int")"

        guard let samples = AudioFormatConverter.extractFloatSamples(from: buffer) else {
            logger.warning(
                "System: extractFloatSamples returned nil for \(formatDesc)"
            )
            return
        }

        let sysCount = sessionState.withLock {
            $0.diagnostics.systemCallbackCount
        }
        let frameCount = buffer.frameLength
        let sampleCount = samples.count
        if sysCount == 0 {
            logger.info("System audio: \(reportedRate)Hz, target=\(targetRate)Hz, \(frameCount)fr, \(channelCount)ch")
            logger.info("System audio detail: \(sampleCount) samples")
        }

        let effectiveSourceRate = targetRate
        let resampled: [Float]
        if channelCount >= 2 {
            resampled = stereoMixer.resampleStereo(
                samples, from: effectiveSourceRate
            )
        } else {
            let mono = stereoMixer.resample(samples, from: effectiveSourceRate)
            resampled = stereoMixer.interleave(left: mono, right: mono)
        }

        if sysCount == 0 {
            let inCount = samples.count
            let outCount = resampled.count
            logger.info(
                "System audio after resample: in=\(inCount) out=\(outCount) (effective source=\(effectiveSourceRate)Hz)"
            )
        }

        updateSystemLevel(samples: resampled)
        sessionState.withLock {
            $0.diagnostics.systemCallbackCount += 1
            $0.diagnostics.systemSamplesTotal += resampled.count
            $0.diagnostics.systemFormat =
                "\(Int(reportedRate))->\(Int(targetRate))Hz \(channelCount)ch"
        }
        Task { await systemBuffer?.write(resampled) }
    }

    // MARK: - Level Metering

    func updateMicLevel(samples: [Float]) {
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

    func updateSystemLevel(samples: [Float]) {
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

    // MARK: - Mic Rate Detection

    /// Starts mic capture briefly to detect the actual sample rate after
    /// Bluetooth HFP negotiation. Waits up to 500ms for the rate to stabilize.
    func detectMicRate(config: CaptureConfiguration) async throws -> Double {
        let lowestRate = UnfairLock(config.sampleRate)

        try await micCapture.start { buffer, _ in
            let rate = buffer.format.sampleRate
            lowestRate.withLock { current in
                if rate < current { current = rate }
            }
        }

        try? await Task.sleep(nanoseconds: 500_000_000)

        let result = lowestRate.withLock { $0 }
        logger.info("Mic rate probe detected: \(result)Hz (after 500ms settling)")
        return result
    }

    // MARK: - Recording Finalization

    /// Closes the file writer and builds the recording result.
    func finalizeRecording() async throws -> RecordingResult {
        guard let writer = fileWriter else {
            throw CaptureError.storageError("No file writer available")
        }

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
                AudioTrack(type: .system, channel: .stereo),
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
}
