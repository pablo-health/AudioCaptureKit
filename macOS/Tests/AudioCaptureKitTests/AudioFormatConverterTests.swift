import Foundation
import Testing
@testable import AudioCaptureKit

@Suite("AudioFormatConverter Tests")
struct AudioFormatConverterTests {

    @Test("WAV header is exactly 44 bytes")
    func wavHeaderSize() {
        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: 48000, bitDepth: 16, channels: 2, dataSize: 0
        )
        #expect(header.count == 44)
    }

    @Test("WAV header starts with RIFF")
    func wavHeaderRIFF() {
        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: 48000, bitDepth: 16, channels: 2, dataSize: 1000
        )
        #expect(String(data: header[0..<4], encoding: .ascii) == "RIFF")
    }

    @Test("WAV header contains WAVE format")
    func wavHeaderWAVE() {
        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: 48000, bitDepth: 16, channels: 2, dataSize: 1000
        )
        #expect(String(data: header[8..<12], encoding: .ascii) == "WAVE")
    }

    @Test("WAV header contains fmt chunk")
    func wavHeaderFmtChunk() {
        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: 48000, bitDepth: 16, channels: 2, dataSize: 1000
        )
        #expect(String(data: header[12..<16], encoding: .ascii) == "fmt ")
    }

    @Test("WAV header contains data chunk")
    func wavHeaderDataChunk() {
        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: 48000, bitDepth: 16, channels: 2, dataSize: 1000
        )
        #expect(String(data: header[36..<40], encoding: .ascii) == "data")
    }

    @Test("WAV header encodes correct sample rate")
    func wavHeaderSampleRate() {
        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: 48000, bitDepth: 16, channels: 2, dataSize: 0
        )
        let sampleRate = header.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) }
        #expect(sampleRate == 48000)
    }

    @Test("WAV header encodes correct channel count")
    func wavHeaderChannels() {
        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: 48000, bitDepth: 16, channels: 2, dataSize: 0
        )
        let channels = header.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self) }
        #expect(channels == 2)
    }

    @Test("WAV header encodes correct bit depth")
    func wavHeaderBitDepth() {
        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: 48000, bitDepth: 16, channels: 2, dataSize: 0
        )
        let bitDepth = header.withUnsafeBytes { $0.load(fromByteOffset: 34, as: UInt16.self) }
        #expect(bitDepth == 16)
    }

    @Test("WAV header byte rate calculation is correct")
    func wavHeaderByteRate() {
        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: 48000, bitDepth: 16, channels: 2, dataSize: 0
        )
        let byteRate = header.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) }
        #expect(byteRate == 192000)
    }

    @Test("WAV header block align is correct")
    func wavHeaderBlockAlign() {
        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: 48000, bitDepth: 16, channels: 2, dataSize: 0
        )
        let blockAlign = header.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt16.self) }
        #expect(blockAlign == 4)
    }

    @Test("WAV header chunk size includes data size")
    func wavHeaderChunkSize() {
        let dataSize: UInt32 = 96000
        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: 48000, bitDepth: 16, channels: 2, dataSize: dataSize
        )
        let chunkSize = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        #expect(chunkSize == 36 + dataSize)
    }

    @Test("WAV header data size field")
    func wavHeaderDataSize() {
        let dataSize: UInt32 = 192000
        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: 48000, bitDepth: 16, channels: 2, dataSize: dataSize
        )
        let stored = header.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }
        #expect(stored == dataSize)
    }

    @Test("WAV header audio format is PCM")
    func wavHeaderPCMFormat() {
        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: 48000, bitDepth: 16, channels: 2, dataSize: 0
        )
        let fmt = header.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt16.self) }
        #expect(fmt == 1)
    }

    @Test("WAV header for mono 44100Hz 16-bit")
    func wavHeaderMono44100() {
        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: 44100, bitDepth: 16, channels: 1, dataSize: 0
        )
        let sr = header.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) }
        let ch = header.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self) }
        let br = header.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) }
        #expect(sr == 44100)
        #expect(ch == 1)
        #expect(br == 88200)
    }
}
