import AVFoundation
import Foundation
import os

// MARK: - Per-channel sidecar files (raw PCM or streaming AAC)

extension CompositeCaptureSession {
    /// Opens the per-channel sidecar files for raw channel export.
    ///
    /// The container follows ``CaptureConfiguration/sidecarFormat``: raw
    /// signed-16-bit PCM (`.pcm`) or streaming AAC-LC in an ADTS stream (`.aac`).
    /// When an encryptor is configured both use the `.enc.*` extension and the
    /// same length-prefixed encrypted-chunk format (no plaintext on disk).
    func openPCMSidecarFiles(baseName: String, directory: URL) {
        let isAAC = configuration.sidecarFormat == .aacADTS
        let encrypted = configuration.encryptor != nil
        let ext = switch (isAAC, encrypted) {
        case (true, true): "enc.aac"
        case (true, false): "aac"
        case (false, true): "enc.pcm"
        case (false, false): "pcm"
        }
        let micURL = directory.appendingPathComponent("\(baseName)_mic.\(ext)")
        let systemURL = directory.appendingPathComponent("\(baseName)_system.\(ext)")
        let fm = FileManager.default

        var handles: (mic: FileHandle?, system: FileHandle?) = (nil, nil)

        if fm.createFile(atPath: micURL.path, contents: nil) {
            handles.mic = FileHandle(forWritingAtPath: micURL.path)
        } else {
            logger.warning("Failed to create mic sidecar: \(micURL.lastPathComponent)")
        }

        if fm.createFile(atPath: systemURL.path, contents: nil) {
            handles.system = FileHandle(forWritingAtPath: systemURL.path)
        } else {
            logger.warning("Failed to create system sidecar: \(systemURL.lastPathComponent)")
        }

        // For AAC, wrap each open handle in a streaming encoder whose frames are
        // written with the same (optionally encrypted) chunk format as PCM. If an
        // encoder can't be built, fall back to leaving raw PCM in that channel.
        let encoders = isAAC
            ? makeAACEncoders(micHandle: handles.mic, systemHandle: handles.system)
            : (mic: nil, system: nil)

        sessionState.withLock {
            $0.micPCMFileHandle = handles.mic
            $0.systemPCMFileHandle = handles.system
            $0.micAACEncoder = encoders.mic
            $0.systemAACEncoder = encoders.system
            var urls: [URL] = []
            if handles.mic != nil { urls.append(micURL) }
            if handles.system != nil { urls.append(systemURL) }
            $0.rawPCMFileURLs = urls
        }
    }

    /// Builds AAC encoders bound to the sidecar file handles. Each encoder emits
    /// ADTS frames on the PCM I/O queue via ``AACStreamEncoder/FrameSink``; the
    /// sink reuses ``writePCMChunk`` so encryption + framing match the PCM path.
    private func makeAACEncoders(
        micHandle: FileHandle?,
        systemHandle: FileHandle?
    ) -> (mic: AACStreamEncoder?, system: AACStreamEncoder?) {
        let rate = stereoMixer.targetSampleRate
        let bitRate = configuration.sidecarAACBitRate
        let encryptor = configuration.encryptor
        let log = logger

        let mic = micHandle.flatMap { handle in
            AACStreamEncoder(sampleRate: rate, channels: 1, bitRate: bitRate, logger: log) { frame in
                Self.writePCMChunk(frame, to: handle, encryptor: encryptor, logger: log)
            }
        }
        let system = systemHandle.flatMap { handle in
            AACStreamEncoder(sampleRate: rate, channels: 2, bitRate: bitRate, logger: log) { frame in
                Self.writePCMChunk(frame, to: handle, encryptor: encryptor, logger: log)
            }
        }
        return (mic, system)
    }

    /// Writes one processing cycle's per-channel samples to the sidecars.
    ///
    /// For AAC, hands the Float samples straight to the streaming encoder on the
    /// I/O queue; it emits ADTS frames to the same sidecar handles. Otherwise
    /// converts to Int16 PCM and appends (optionally encrypted) chunks. The
    /// encoder is single-producer, so all its calls stay on this serial queue.
    func writeRawPCMSidecars(micSamples: [Float], systemSamples: [Float]) {
        let (micHandle, systemHandle, micEncoder, systemEncoder) = sessionState.withLock {
            ($0.micPCMFileHandle, $0.systemPCMFileHandle, $0.micAACEncoder, $0.systemAACEncoder)
        }

        if micEncoder != nil || systemEncoder != nil {
            pcmWriteQueue.async {
                micEncoder?.encode(micSamples)
                systemEncoder?.encode(systemSamples)
            }
            return
        }

        let encryptor = configuration.encryptor

        // Convert in-memory (fast), then dispatch the blocking FileHandle writes
        // to a dedicated I/O queue so the processing loop can drain the next cycle.
        let micPCM = micHandle != nil ? stereoMixer.convertToInt16PCM(micSamples) : nil
        let systemPCM = systemHandle != nil ? stereoMixer.convertToInt16PCM(systemSamples) : nil
        pcmWriteQueue.async { [logger] in
            if let micPCM {
                Self.writePCMChunk(micPCM, to: micHandle, encryptor: encryptor, logger: logger)
            }
            if let systemPCM {
                Self.writePCMChunk(systemPCM, to: systemHandle, encryptor: encryptor, logger: logger)
            }
        }
    }

    /// Writes a single sidecar chunk, encrypting with the same length-prefixed
    /// format as `EncryptedFileWriter` when an encryptor is provided.
    static func writePCMChunk(
        _ data: Data,
        to handle: FileHandle?,
        encryptor: (any CaptureEncryptor)?,
        logger: Logger
    ) {
        guard let handle else { return }
        if let encryptor {
            do {
                let encrypted = try encryptor.encrypt(data)
                var chunkLength = UInt32(encrypted.count).littleEndian
                handle.write(Data(bytes: &chunkLength, count: 4))
                handle.write(encrypted)
            } catch {
                logger.error("Sidecar chunk encryption failed: \(error)")
            }
        } else {
            handle.write(data)
        }
    }
}
