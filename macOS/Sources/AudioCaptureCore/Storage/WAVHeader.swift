import Foundation

/// Builds the 44-byte canonical WAV/RIFF header.
///
/// Pure byte layout — no audio framework involved. It lived on
/// `AudioFormatConverter` alongside functions that take `AVAudioPCMBuffer`,
/// which pinned it to macOS by association and forced `EncryptedFileWriter`
/// (Foundation-only in every other respect) to stay there too.
public enum WAVHeader {
    /// - Parameter dataSize: byte count of the audio payload. Pass 0 when the
    ///   length is not yet known and patch it on close — a streaming writer does
    ///   not know the size until it stops.
    public static func make(
        sampleRate: UInt32,
        bitDepth: UInt16,
        channels: UInt16,
        dataSize: UInt32
    ) -> Data {
        var header = Data(capacity: 44)

        let byteRate = sampleRate * UInt32(channels) * UInt32(bitDepth) / 8
        let blockAlign = channels * bitDepth / 8
        let chunkSize = 36 + dataSize

        // RIFF chunk descriptor
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendUInt32(&header, chunkSize)
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // "fmt " sub-chunk
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendUInt32(&header, 16) // PCM sub-chunk size
        appendUInt16(&header, 1) // format 1 = PCM
        appendUInt16(&header, channels)
        appendUInt32(&header, sampleRate)
        appendUInt32(&header, byteRate)
        appendUInt16(&header, blockAlign)
        appendUInt16(&header, bitDepth)

        // "data" sub-chunk
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendUInt32(&header, dataSize)

        return header
    }

    static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
