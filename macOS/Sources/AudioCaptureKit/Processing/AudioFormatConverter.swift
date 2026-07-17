import AudioToolbox
import AVFoundation
import Foundation
import os

/// Converts audio data between formats and generates WAV file headers.
///
/// `AudioFormatConverter` handles conversion to the target recording format
/// (48kHz, 16-bit PCM, WAV) and provides utilities for WAV header generation.
public struct AudioFormatConverter: Sendable {
    private static let logger = Logger(
        subsystem: "com.audiocapturekit",
        category: "AudioFormatConverter"
    )

    /// Generates a standard WAV file header.
    ///
    /// The header follows the RIFF/WAVE format specification:
    /// - RIFF chunk descriptor
    /// - "fmt " sub-chunk with PCM format data
    /// - "data" sub-chunk header
    ///
    /// - Parameters:
    ///   - sampleRate: Sample rate in Hz (e.g., 48000).
    ///   - bitDepth: Bits per sample (e.g., 16).
    ///   - channels: Number of audio channels (e.g., 2 for stereo).
    ///   - dataSize: Size of the audio data in bytes. Use 0 if unknown (update later).
    /// - Returns: A 44-byte WAV header as `Data`.
    /// Delegates to `WAVHeader` in AudioCaptureCore, kept here so existing
    /// callers do not have to change. The header is pure byte layout and does
    /// not belong beside the AVFoundation conversion helpers below.
    public static func generateWAVHeader(
        sampleRate: UInt32,
        bitDepth: UInt16,
        channels: UInt16,
        dataSize: UInt32
    ) -> Data {
        WAVHeader.make(
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            dataSize: dataSize
        )
    }

    /// Extracts float samples from an `AVAudioPCMBuffer`.
    ///
    /// For non-interleaved multi-channel buffers, returns interleaved samples.
    /// For interleaved buffers, returns the raw interleaved data.
    ///
    /// - Parameter buffer: The audio buffer to extract samples from.
    /// - Returns: An array of Float32 samples, or `nil` if the buffer has no float data.
    public static func extractFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0 else { return nil }

        if buffer.format.isInterleaved {
            // For interleaved buffers, floatChannelData is nil.
            // Access the raw data through the audio buffer list directly.
            let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard let firstBuf = abl.first, let data = firstBuf.mData else { return nil }
            let totalSamples = frameCount * channelCount
            let ptr = data.bindMemory(to: Float.self, capacity: totalSamples)
            return Array(UnsafeBufferPointer(start: ptr, count: totalSamples))
        }

        guard let channelData = buffer.floatChannelData else { return nil }

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }

        // For non-interleaved multi-channel, interleave the channels
        var samples = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0 ..< frameCount {
            for channel in 0 ..< channelCount {
                samples[frame * channelCount + channel] = channelData[channel][frame]
            }
        }
        return samples
    }

    /// Extracts float samples and downmixes to mono.
    ///
    /// For mono buffers, returns the samples directly. For stereo/multi-channel
    /// buffers, averages all channels per frame to produce a mono output.
    ///
    /// - Parameter buffer: The audio buffer to extract from.
    /// - Returns: Mono Float32 samples, or `nil` if the buffer has no data.
    public static func extractMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0 else { return nil }

        if channelCount == 1 {
            return extractFloatSamples(from: buffer)
        }

        // Get interleaved samples then average channels per frame
        guard let interleaved = extractFloatSamples(from: buffer) else { return nil }
        var mono = [Float](repeating: 0, count: frameCount)
        let scale = 1.0 / Float(channelCount)
        for frame in 0 ..< frameCount {
            var sum: Float = 0
            for ch in 0 ..< channelCount {
                sum += interleaved[frame * channelCount + ch]
            }
            mono[frame] = sum * scale
        }
        return mono
    }

    // MARK: - Private Helpers

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
