import Crypto
import Foundation
import AudioCaptureKit

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  WARNING: DEMO ONLY — DO NOT USE IN PRODUCTION                         ║
// ║                                                                        ║
// ║  This encryptor uses a hardcoded key for demonstration purposes.       ║
// ║  In a production application, encryption keys must be:                 ║
// ║    - Generated per-user or per-session                                 ║
// ║    - Stored securely in the macOS Keychain                             ║
// ║    - Never committed to source control                                 ║
// ║    - Rotated on a regular schedule                                     ║
// ║                                                                        ║
// ║  This exists solely to demonstrate the AudioCaptureKit encryption      ║
// ║  pipeline in the sample app.                                           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

/// A demonstration encryptor that uses AES-256-GCM with a hardcoded key.
struct DemoEncryptor: CaptureEncryptor {
    // WARNING: Hardcoded demo key — NOT for production use.
    private static let demoKeyBytes: [UInt8] = [
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
    ]

    private let key: SymmetricKey

    init() {
        self.key = SymmetricKey(data: Self.demoKeyBytes)
    }

    var algorithm: String { "AES-256-GCM" }

    func encrypt(_ data: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else {
                throw CaptureError.encryptionFailed("Failed to produce combined sealed box")
            }
            return combined
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.encryptionFailed(error.localizedDescription)
        }
    }

    func decrypt(_ data: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw CaptureError.encryptionFailed("Decryption failed: \(error.localizedDescription)")
        }
    }

    /// Decrypts an encrypted WAV file and returns complete in-memory WAV data.
    ///
    /// File format: 44-byte WAV header followed by encrypted chunks.
    /// Each chunk: 4-byte UInt32 length prefix (little-endian) + combined sealed box data.
    static func decryptFile(at url: URL) throws -> Data {
        let fileData = try Data(contentsOf: url)
        let headerSize = 44
        guard fileData.count > headerSize else {
            throw CaptureError.encryptionFailed("File too small to contain WAV header")
        }

        let header = fileData.prefix(headerSize)
        var offset = headerSize
        let encryptor = DemoEncryptor()
        var pcmData = Data()

        while offset + 4 <= fileData.count {
            let lengthBytes = fileData[offset..<offset + 4]
            let chunkLength = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
            let length = Int(UInt32(littleEndian: chunkLength))
            offset += 4

            guard offset + length <= fileData.count else {
                throw CaptureError.encryptionFailed("Encrypted chunk exceeds file bounds")
            }

            let chunkData = fileData[offset..<offset + length]
            let decrypted = try encryptor.decrypt(Data(chunkData))
            pcmData.append(decrypted)
            offset += length
        }

        // Rebuild WAV with correct data size in header
        var wav = Data(header)
        let dataSize = UInt32(pcmData.count)
        let fileSize = UInt32(36 + pcmData.count)
        // Update RIFF chunk size (bytes 4-7)
        wav.replaceSubrange(4..<8, with: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        // Update data sub-chunk size (bytes 40-43)
        wav.replaceSubrange(40..<44, with: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wav.append(pcmData)

        return wav
    }

    func keyMetadata() -> [String: String] {
        [
            "keyId": "demo-key-v1",
            "algorithm": algorithm,
            "warning": "DEMO KEY — NOT FOR PRODUCTION",
        ]
    }
}
