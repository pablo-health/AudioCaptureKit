import Crypto
import Foundation
import os

/// Writes audio data to disk with optional AES-256-GCM encryption.
///
/// `EncryptedFileWriter` supports streaming writes, encrypting audio data
/// in chunks as it arrives rather than buffering the entire recording in memory.
/// Each chunk is independently sealed with AES-256-GCM, with the nonce and tag
/// stored alongside the ciphertext.
///
/// Uses `UnfairLock` instead of an actor to avoid async scheduling overhead
/// on the audio write path. The processing loop fires every 100 ms; actor hops
/// can add variable latency that compounds over long recordings.
///
/// File format for encrypted files (.enc.wav):
/// - 44-byte WAV header (unencrypted, for format identification)
/// - Repeating encrypted chunks:
///   - 4 bytes: chunk length (UInt32, little-endian, length of nonce + ciphertext + tag)
///   - 12 bytes: nonce
///   - N bytes: ciphertext
///   - 16 bytes: authentication tag
public final class EncryptedFileWriter: @unchecked Sendable {
    private struct State {
        var fileHandle: FileHandle?
        var totalBytesWritten: UInt64 = 0
        var isOpen = false
    }

    private let fileURL: URL
    private let encryptor: (any CaptureEncryptor)?
    private let state: UnfairLock<State>

    private let logger = Logger(
        subsystem: "com.audiocapturekit",
        category: "EncryptedFileWriter"
    )

    /// Creates a new encrypted file writer.
    /// - Parameters:
    ///   - fileURL: The destination file URL.
    ///   - encryptor: Optional encryptor for encrypting audio data.
    public init(fileURL: URL, encryptor: (any CaptureEncryptor)? = nil) {
        self.fileURL = fileURL
        self.encryptor = encryptor
        self.state = UnfairLock(State())
    }

    /// Opens the file for writing and writes the WAV header.
    /// - Parameter configuration: The audio configuration for generating the WAV header.
    /// - Throws: ``CaptureError/storageError(_:)`` if the file cannot be created.
    public func open(configuration: CaptureConfiguration) throws {
        try state.withLock { ws in
            guard !ws.isOpen else { return }

            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CaptureError.storageError("Failed to create file: \(fileURL.lastPathComponent)")
            }

            ws.fileHandle = try FileHandle(forWritingTo: fileURL)

            let header = AudioFormatConverter.generateWAVHeader(
                sampleRate: UInt32(configuration.sampleRate),
                bitDepth: UInt16(configuration.bitDepth),
                channels: UInt16(configuration.channels),
                dataSize: 0
            )
            ws.fileHandle?.write(header)
            ws.totalBytesWritten = UInt64(header.count)
            ws.isOpen = true
        }

        logger.info("Opened file for writing: \(self.fileURL.lastPathComponent)")
    }

    /// Writes a chunk of audio data, optionally encrypting it.
    ///
    /// When encryption is enabled, each chunk is written as:
    /// - 4 bytes: chunk length (UInt32, little-endian) — length of the sealed box data
    /// - N bytes: AES-GCM combined sealed box (nonce + ciphertext + tag)
    ///
    /// - Parameter data: The raw PCM audio data to write.
    /// - Throws: ``CaptureError`` if encryption or writing fails.
    public func write(_ data: Data) throws {
        // Encrypt outside the lock — AES-GCM is CPU work, not state mutation.
        let encrypted: Data? = if let encryptor {
            try encryptor.encrypt(data)
        } else {
            nil
        }

        try state.withLock { ws in
            guard ws.isOpen, let fileHandle = ws.fileHandle else {
                throw CaptureError.storageError("File is not open for writing")
            }

            if let encrypted {
                var chunkLength = UInt32(encrypted.count).littleEndian
                let lengthData = Data(bytes: &chunkLength, count: 4)
                fileHandle.write(lengthData)
                fileHandle.write(encrypted)
                ws.totalBytesWritten += UInt64(4 + encrypted.count)
            } else {
                fileHandle.write(data)
                ws.totalBytesWritten += UInt64(data.count)
            }
        }
    }

    /// Finalizes and closes the file, updating the WAV header with the correct data size.
    /// - Parameters:
    ///   - actualSampleRate: If provided, updates the WAV header sample rate.
    ///     Used when the actual device rate differs from the initial configuration
    ///     (e.g. Bluetooth HFP negotiation changes the rate after capture starts).
    /// - Returns: The SHA-256 checksum of the completed file.
    /// - Throws: ``CaptureError/storageError(_:)`` if finalization fails.
    @discardableResult
    public func close(
        actualSampleRate: Double? = nil,
        channels: UInt16 = 2,
        bitDepth: UInt16 = 16
    ) throws -> String {
        let totalBytes: UInt64 = try state.withLock { ws in
            guard ws.isOpen, let fileHandle = ws.fileHandle else {
                throw CaptureError.storageError("File is not open")
            }

            finalizeWAVHeader(
                fileHandle: fileHandle,
                totalBytesWritten: ws.totalBytesWritten,
                actualSampleRate: actualSampleRate,
                channels: channels,
                bitDepth: bitDepth
            )

            fileHandle.closeFile()
            ws.fileHandle = nil
            ws.isOpen = false
            return ws.totalBytesWritten
        }

        let checksum = try streamingSHA256(fileURL: fileURL)
        logger.info("Closed file: \(self.fileURL.lastPathComponent), size: \(totalBytes) bytes")
        return checksum
    }

    /// The total number of bytes written to the file.
    public var bytesWritten: UInt64 {
        state.withLock { $0.totalBytesWritten }
    }

    // MARK: - WAV Header

    private func finalizeWAVHeader(
        fileHandle: FileHandle,
        totalBytesWritten: UInt64,
        actualSampleRate: Double?,
        channels: UInt16,
        bitDepth: UInt16
    ) {
        let dataSize = totalBytesWritten - 44
        fileHandle.seek(toFileOffset: 4)
        var fileSize = UInt32(truncatingIfNeeded: totalBytesWritten - 8)
        fileHandle.write(Data(bytes: &fileSize, count: 4))

        if let rate = actualSampleRate {
            let sampleRate = UInt32(rate)
            let byteRate = sampleRate * UInt32(channels) * UInt32(bitDepth) / 8
            let blockAlign = channels * bitDepth / 8

            fileHandle.seek(toFileOffset: 24)
            var sr = sampleRate.littleEndian
            fileHandle.write(Data(bytes: &sr, count: 4))

            var br = byteRate.littleEndian
            fileHandle.write(Data(bytes: &br, count: 4))

            var ba = blockAlign.littleEndian
            fileHandle.write(Data(bytes: &ba, count: 2))
        }

        fileHandle.seek(toFileOffset: 40)
        var dataSizeValue = UInt32(truncatingIfNeeded: dataSize)
        fileHandle.write(Data(bytes: &dataSizeValue, count: 4))
    }

    // MARK: - Streaming Checksum

    private func streamingSHA256(fileURL: URL) throws -> String {
        let readHandle = try FileHandle(forReadingFrom: fileURL)
        defer { readHandle.closeFile() }

        var hasher = SHA256()
        let chunkSize = 256 * 1024 // 256 KB
        while autoreleasepool(invoking: {
            let chunk = readHandle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
