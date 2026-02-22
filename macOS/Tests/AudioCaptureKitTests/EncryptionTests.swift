@testable import AudioCaptureKit
import Crypto
import Foundation
import Testing

/// A concrete AES-256-GCM encryptor for testing.
struct AES256GCMEncryptor: CaptureEncryptor {
    let key: SymmetricKey
    let keyId: String

    init(keyId: String = "test-key-001") {
        self.key = SymmetricKey(size: .bits256)
        self.keyId = keyId
    }

    var algorithm: String { "AES-256-GCM" }

    func encrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw CaptureError.encryptionFailed("Failed to get combined sealed box data")
        }
        return combined
    }

    func decrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: key)
    }

    func keyMetadata() -> [String: String] {
        [
            "keyId": keyId,
            "algorithm": algorithm,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ]
    }
}

@Suite("Encryption Tests")
struct EncryptionTests {

    @Test("AES-256-GCM round-trip encrypt/decrypt")
    func roundTripEncryptDecrypt() throws {
        let encryptor = AES256GCMEncryptor()
        let originalData = Data("Hello, HIPAA-compliant world!".utf8)
        let encrypted = try encryptor.encrypt(originalData)
        let decrypted = try encryptor.decrypt(encrypted)
        #expect(decrypted == originalData)
        #expect(encrypted != originalData)
    }

    @Test("Encrypted data is larger than original due to nonce and tag")
    func encryptedDataSizeIncrease() throws {
        let encryptor = AES256GCMEncryptor()
        let originalData = Data(repeating: 0xAB, count: 1024)
        let encrypted = try encryptor.encrypt(originalData)
        // AES-GCM combined: 12 (nonce) + data + 16 (tag) = data + 28
        #expect(encrypted.count == originalData.count + 28)
    }

    @Test("Different encryptions produce different ciphertexts")
    func uniqueNonces() throws {
        let encryptor = AES256GCMEncryptor()
        let data = Data("Same plaintext".utf8)
        let encrypted1 = try encryptor.encrypt(data)
        let encrypted2 = try encryptor.encrypt(data)
        #expect(encrypted1 != encrypted2)
        #expect(try encryptor.decrypt(encrypted1) == data)
        #expect(try encryptor.decrypt(encrypted2) == data)
    }

    @Test("Decryption with wrong key fails")
    func decryptionWithWrongKey() throws {
        let encryptor1 = AES256GCMEncryptor(keyId: "key-1")
        let encryptor2 = AES256GCMEncryptor(keyId: "key-2")
        let data = Data("Secret data".utf8)
        let encrypted = try encryptor1.encrypt(data)
        #expect(throws: (any Error).self) {
            try encryptor2.decrypt(encrypted)
        }
    }

    @Test("Tampered ciphertext fails authentication")
    func tamperedCiphertextFails() throws {
        let encryptor = AES256GCMEncryptor()
        let data = Data("Integrity-protected data".utf8)
        var encrypted = try encryptor.encrypt(data)
        if encrypted.count > 20 { encrypted[15] ^= 0xFF }
        #expect(throws: (any Error).self) {
            try encryptor.decrypt(encrypted)
        }
    }

    @Test("Encryptor reports correct algorithm")
    func algorithmName() {
        let encryptor = AES256GCMEncryptor()
        #expect(encryptor.algorithm == "AES-256-GCM")
    }

    @Test("Key metadata contains required fields")
    func keyMetadataFields() {
        let encryptor = AES256GCMEncryptor(keyId: "test-key-42")
        let metadata = encryptor.keyMetadata()
        #expect(metadata["keyId"] == "test-key-42")
        #expect(metadata["algorithm"] == "AES-256-GCM")
        #expect(metadata["createdAt"] != nil)
    }

    @Test("Encrypt empty data")
    func encryptEmptyData() throws {
        let encryptor = AES256GCMEncryptor()
        let encrypted = try encryptor.encrypt(Data())
        let decrypted = try encryptor.decrypt(encrypted)
        #expect(decrypted == Data())
        #expect(encrypted.count == 28)
    }

    @Test("Encrypt large audio-sized data")
    func encryptLargeData() throws {
        let encryptor = AES256GCMEncryptor()
        let audioData = Data(repeating: 0x42, count: 192_000)
        let encrypted = try encryptor.encrypt(audioData)
        let decrypted = try encryptor.decrypt(encrypted)
        #expect(decrypted == audioData)
        #expect(decrypted.count == 192_000)
    }
}
