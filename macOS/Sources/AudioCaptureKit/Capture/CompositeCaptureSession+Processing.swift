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

                let currentState = sessionState.withLock { $0.state }
                if case .capturing = currentState {
                    let duration = elapsedDuration()
                    setState(.capturing(duration: duration))

                    if let maxDuration = configuration.maxDuration, duration >= maxDuration {
                        _ = try? await stopCapture()
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

                let currentState = sessionState.withLock { $0.state }
                if case .capturing = currentState {
                    await processBuffers()
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
            logger.warning("System: extractFloatSamples returned nil for \(formatDesc)")
            return
        }

        let sysCount = sessionState.withLock { $0.diagnostics.systemCallbackCount }
        if sysCount == 0 {
            logFirstSystemCallback(buffer: buffer, samples: samples, targetRate: targetRate)
        }

        let resampled = resampleSystemAudio(samples, channelCount: channelCount, sourceRate: targetRate)

        if sysCount == 0 {
            logger.info("System audio after resample: in=\(samples.count) out=\(resampled.count)")
        }

        updateSystemLevel(samples: resampled)
        sessionState.withLock {
            $0.diagnostics.systemCallbackCount += 1
            $0.diagnostics.systemSamplesTotal += resampled.count
            $0.diagnostics.systemFormat = "\(Int(reportedRate))->\(Int(targetRate))Hz \(channelCount)ch"
        }
        Task { await systemBuffer?.write(resampled) }
    }

    private func logFirstSystemCallback(buffer: AVAudioPCMBuffer, samples: [Float], targetRate: Double) {
        let rate = buffer.format.sampleRate
        let ch = Int(buffer.format.channelCount)
        logger.info("System audio: \(rate)Hz, target=\(targetRate)Hz, \(buffer.frameLength)fr, \(ch)ch")
        logger.info("System audio detail: \(samples.count) samples")
    }

    private func resampleSystemAudio(_ samples: [Float], channelCount: Int, sourceRate: Double) -> [Float] {
        if channelCount >= 2 {
            return stereoMixer.resampleStereo(samples, from: sourceRate)
        }
        let mono = stereoMixer.resample(samples, from: sourceRate)
        return stereoMixer.interleave(left: mono, right: mono)
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

        let result = buildRecordingResult(checksum: checksum)
        setState(.completed(result))

        let delegate = sessionState.withLock { $0.delegate }
        delegate?.captureSession(self, didFinishCapture: result)
        return result
    }

    private func buildRecordingResult(checksum: String) -> RecordingResult {
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

        return RecordingResult(fileURL: fileURL, duration: duration, metadata: metadata, checksum: checksum)
    }
}
