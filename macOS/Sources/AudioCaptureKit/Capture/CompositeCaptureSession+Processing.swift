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

    /// Called from audio callbacks when the ring buffer crosses the threshold.
    /// Dispatches processing to a dedicated queue so the audio thread returns immediately.
    func scheduleProcessingIfNeeded() {
        let alreadyScheduled = processingScheduled.withLock { scheduled in
            if scheduled { return true }
            scheduled = true
            return false
        }
        guard !alreadyScheduled else { return }

        processingQueue.async { [weak self] in
            guard let self else { return }
            self.processingScheduled.withLock { $0 = false }

            let currentState = self.sessionState.withLock { $0.state }
            if case .capturing = currentState {
                // Process synchronously on the processing queue — no Task.sleep, no cooperative pool.
                self.processBuffersSync()
            }
        }
    }

    /// Synchronous version of processBuffers for use on the dedicated processing queue.
    private func processBuffersSync() {
        guard let writer = fileWriter else { return }

        let config = configuration
        let chunkSize = Int(config.sampleRate) // 1 second of frames

        guard let (micSamples, systemSamples) =
            readPendingSamplesSync(config: config, chunkSize: chunkSize) else { return }

        let channelBuffers = ChannelBuffers(
            micSamples: micSamples,
            systemSamples: systemSamples,
            sampleRate: stereoMixer.targetSampleRate
        )
        let preDelegate = sessionState.withLock { $0.delegate }
        preDelegate?.captureSession(self, didProduceChannelBuffers: channelBuffers)

        let stereoSamples = stereoMixer.mix(
            mic: micSamples,
            system: systemSamples,
            strategy: configuration.mixingStrategy
        )
        let pcmData = stereoMixer.convertToInt16PCM(stereoSamples)

        if config.exportRawPCM {
            writeRawPCMSidecars(micSamples: micSamples, systemSamples: systemSamples)
        }

        sessionState.withLock {
            $0.diagnostics.mixCycles += 1
            $0.diagnostics.bytesWritten += pcmData.count
        }

        do {
            try writer.write(pcmData)
        } catch {
            let delegate = sessionState.withLock { $0.delegate }
            if let captureError = error as? CaptureError {
                delegate?.captureSession(self, didEncounterError: captureError)
            }
        }
    }

    /// Reads pending samples synchronously (no actor/async needed).
    private func readPendingSamplesSync(
        config: CaptureConfiguration,
        chunkSize: Int
    ) -> (mic: [Float], system: [Float])? {
        guard let micBuf = micBuffer, let sysBuf = systemBuffer else { return nil }

        if config.enableSystemCapture {
            let frames = min(sysBuf.count / 2, chunkSize)
            guard frames > 0 else { return nil }
            return (mic: micBuf.read(count: frames), system: sysBuf.read(count: frames * 2))
        } else {
            let mic = micBuf.read(count: chunkSize)
            return mic.isEmpty ? nil : (mic: mic, system: [])
        }
    }

    /// Async version used only for the final drain in stopCapture.
    func processBuffers() async {
        processBuffersSync()
    }

    private func writeRawPCMSidecars(micSamples: [Float], systemSamples: [Float]) {
        let (micHandle, systemHandle) = sessionState.withLock {
            ($0.micPCMFileHandle, $0.systemPCMFileHandle)
        }
        // Convert in-memory (fast), then dispatch the blocking FileHandle writes
        // to a dedicated I/O queue so the processing loop can drain the next cycle.
        let micPCM = micHandle != nil ? stereoMixer.convertToInt16PCM(micSamples) : nil
        let systemPCM = systemHandle != nil ? stereoMixer.convertToInt16PCM(systemSamples) : nil
        pcmWriteQueue.async {
            if let micPCM { micHandle?.write(micPCM) }
            if let systemPCM { systemHandle?.write(systemPCM) }
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
        micBuffer?.write(resampled)
        if let micBuffer, micBuffer.count >= processingThreshold {
            scheduleProcessingIfNeeded()
        }
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
        systemBuffer?.write(resampled)
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
            checksum = try writer.close(
                actualSampleRate: actualRate,
                channels: UInt16(configuration.channels),
                bitDepth: UInt16(configuration.bitDepth)
            )
        } catch {
            setState(.failed(.storageError("Failed to close file")))
            throw error
        }

        // Drain any pending PCM writes before closing file handles.
        pcmWriteQueue.sync {}

        let rawPCMURLs: [URL] = sessionState.withLock {
            $0.micPCMFileHandle?.closeFile()
            $0.micPCMFileHandle = nil
            $0.systemPCMFileHandle?.closeFile()
            $0.systemPCMFileHandle = nil
            return $0.rawPCMFileURLs
        }

        let result = buildRecordingResult(checksum: checksum, rawPCMFileURLs: rawPCMURLs)
        setState(.completed(result))

        let delegate = sessionState.withLock { $0.delegate }
        delegate?.captureSession(self, didFinishCapture: result)
        return result
    }

    private func buildRecordingResult(checksum: String, rawPCMFileURLs: [URL] = []) -> RecordingResult {
        let duration = elapsedDuration()
        let config = configuration
        let fileURL: URL = sessionState.withLock { $0.fileURL! }

        let (tracks, channelLayout): ([AudioTrack], ChannelLayout)
        switch config.mixingStrategy {
        case .separated, .multichannel:
            tracks = [
                AudioTrack(type: .mic, channel: .left, label: "Mic (Local)"),
                AudioTrack(type: .system, channel: .right, label: "System (Remote, mono-fold)"),
            ]
            channelLayout = .separatedStereo
        case .blended:
            tracks = [
                AudioTrack(type: .mic, channel: .center),
                AudioTrack(type: .system, channel: .stereo),
            ]
            channelLayout = .blended
        }

        let metadata = RecordingMetadata(
            duration: duration,
            fileURL: fileURL,
            checksum: checksum,
            isEncrypted: config.encryptor != nil,
            tracks: tracks,
            encryptionAlgorithm: config.encryptor?.algorithm,
            encryptionKeyId: config.encryptor?.keyMetadata()["keyId"],
            channelLayout: channelLayout
        )

        return RecordingResult(
            fileURL: fileURL,
            duration: duration,
            metadata: metadata,
            checksum: checksum,
            rawPCMFileURLs: rawPCMFileURLs
        )
    }
}
