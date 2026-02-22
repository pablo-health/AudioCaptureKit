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
/// File format for encrypted files (.enc.wav):
/// - 44-byte WAV header (unencrypted, for format identification)
/// - Repeating encrypted chunks:
///   - 4 bytes: chunk length (UInt32, little-endian, length of nonce + ciphertext + tag)
///   - 12 bytes: nonce
///   - N bytes: ciphertext
///   - 16 bytes: authentication tag
public actor EncryptedFileWriter {
    private let fileURL: URL
    private let encryptor: (any CaptureEncryptor)?
    private var fileHandle: FileHandle?
    private var totalBytesWritten: UInt64 = 0
    private var isOpen = false

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
    }

    /// Opens the file for writing and writes the WAV header.
    /// - Parameter configuration: The audio configuration for generating the WAV header.
    /// - Throws: ``CaptureError/storageError(_:)`` if the file cannot be created.
    public func open(configuration: CaptureConfiguration) throws {
        guard !isOpen else { return }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw CaptureError.storageError("Failed to create file at \(fileURL.path)")
        }

        fileHandle = try FileHandle(forWritingTo: fileURL)

        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: UInt32(configuration.sampleRate),
            bitDepth: UInt16(configuration.bitDepth),
            channels: UInt16(configuration.channels),
            dataSize: 0
        )
        fileHandle?.write(header)
        totalBytesWritten = UInt64(header.count)
        isOpen = true

        // swiftformat:disable:next redundantSelf
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
        guard isOpen, let fileHandle else {
            throw CaptureError.storageError("File is not open for writing")
        }

        if let encryptor {
            let encrypted: Data
            do {
                encrypted = try encryptor.encrypt(data)
            } catch {
                throw CaptureError.encryptionFailed("Chunk encryption failed: \(error.localizedDescription)")
            }

            // Write 4-byte length prefix followed by encrypted chunk
            var chunkLength = UInt32(encrypted.count).littleEndian
            let lengthData = Data(bytes: &chunkLength, count: 4)
            fileHandle.write(lengthData)
            fileHandle.write(encrypted)
            totalBytesWritten += UInt64(4 + encrypted.count)
        } else {
            fileHandle.write(data)
            totalBytesWritten += UInt64(data.count)
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
    public func close(actualSampleRate: Double? = nil, channels: UInt16 = 2, bitDepth: UInt16 = 16) throws -> String {
        guard isOpen, let fileHandle else {
            throw CaptureError.storageError("File is not open")
        }

        // Update WAV header with final data size
        let dataSize = totalBytesWritten - 44
        fileHandle.seek(toFileOffset: 4)
        var fileSize = UInt32(truncatingIfNeeded: totalBytesWritten - 8)
        fileHandle.write(Data(bytes: &fileSize, count: 4))

        // If actual sample rate differs, fix up the WAV header
        if let rate = actualSampleRate {
            let sampleRate = UInt32(rate)
            let byteRate = sampleRate * UInt32(channels) * UInt32(bitDepth) / 8
            let blockAlign = channels * bitDepth / 8

            // Offset 24: sample rate (4 bytes)
            fileHandle.seek(toFileOffset: 24)
            var sr = sampleRate.littleEndian
            fileHandle.write(Data(bytes: &sr, count: 4))

            // Offset 28: byte rate (4 bytes)
            var br = byteRate.littleEndian
            fileHandle.write(Data(bytes: &br, count: 4))

            // Offset 32: block align (2 bytes)
            var ba = blockAlign.littleEndian
            fileHandle.write(Data(bytes: &ba, count: 2))

            logger.info("Updated WAV header sample rate to \(sampleRate)Hz")
        }

        fileHandle.seek(toFileOffset: 40)
        var dataSizeValue = UInt32(truncatingIfNeeded: dataSize)
        fileHandle.write(Data(bytes: &dataSizeValue, count: 4))

        fileHandle.closeFile()
        self.fileHandle = nil
        isOpen = false

        // Compute SHA-256 checksum
        let fileData = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: fileData)
        let checksum = digest.map { String(format: "%02x", $0) }.joined()

        // swiftformat:disable:next redundantSelf
        logger.info("Closed file: \(self.fileURL.lastPathComponent), size: \(self.totalBytesWritten) bytes")
        return checksum
    }

    /// The total number of bytes written to the file.
    public var bytesWritten: UInt64 {
        totalBytesWritten
    }
}
