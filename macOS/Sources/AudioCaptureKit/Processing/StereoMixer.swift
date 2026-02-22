import AVFoundation
import Foundation
import os

/// Mixes microphone and system audio into a stereo recording.
///
/// `StereoMixer` takes mono microphone audio and stereo system audio, mixing
/// them into a natural-sounding stereo output where:
/// - **Left**  = mic + system left
/// - **Right** = mic + system right
///
/// This preserves the stereo image of the system audio while placing the
/// microphone in the center of the stereo field, producing a recording
/// suitable for both playback and downstream AI processing.
///
/// If the sources have different sample rates, the mixer resamples to the
/// target rate (default 48kHz).
public struct StereoMixer: Sendable {
    /// The target sample rate for the mixed output.
    public let targetSampleRate: Double

    private static let logger = Logger(
        subsystem: "com.audiocapturekit",
        category: "StereoMixer"
    )

    /// Creates a new stereo mixer.
    /// - Parameter targetSampleRate: The desired output sample rate in Hz. Default is 48000.
    public init(targetSampleRate: Double = 48000) {
        self.targetSampleRate = targetSampleRate
    }

    /// Mixes mono microphone audio with interleaved stereo system audio.
    ///
    /// The mic signal is added equally to both channels, preserving the stereo
    /// image of the system audio. If one source is shorter, it is zero-padded.
    ///
    /// - Parameters:
    ///   - mic: Mono microphone samples.
    ///   - system: Interleaved stereo system audio [L0, R0, L1, R1, ...].
    /// - Returns: Interleaved stereo samples [L0, R0, L1, R1, ...].
    public func mixMicWithStereoSystem(mic: [Float], system: [Float]) -> [Float] {
        let micFrames = mic.count
        let systemFrames = system.count / 2
        let frameCount = max(micFrames, systemFrames)
        guard frameCount > 0 else { return [] }

        var stereo = [Float](repeating: 0, count: frameCount * 2)
        for i in 0 ..< frameCount {
            let micSample = i < micFrames ? mic[i] : 0
            let sysL = (i * 2) < system.count ? system[i * 2] : 0
            let sysR = (i * 2 + 1) < system.count ? system[i * 2 + 1] : 0
            stereo[i * 2] = micSample + sysL
            stereo[i * 2 + 1] = micSample + sysR
        }
        return stereo
    }

    /// Interleaves two mono sample arrays into stereo.
    ///
    /// The left channel receives the first array and the right channel
    /// receives the second. If the arrays differ in length, the shorter
    /// one is zero-padded to match.
    ///
    /// - Parameters:
    ///   - leftSamples: Mono samples for the left channel.
    ///   - rightSamples: Mono samples for the right channel.
    /// - Returns: Interleaved stereo samples [L0, R0, L1, R1, ...].
    public func interleave(left leftSamples: [Float], right rightSamples: [Float]) -> [Float] {
        let frameCount = max(leftSamples.count, rightSamples.count)
        guard frameCount > 0 else { return [] }

        var stereo = [Float](repeating: 0, count: frameCount * 2)
        for i in 0 ..< frameCount {
            stereo[i * 2] = i < leftSamples.count ? leftSamples[i] : 0
            stereo[i * 2 + 1] = i < rightSamples.count ? rightSamples[i] : 0
        }
        return stereo
    }

    /// Converts interleaved Float32 stereo samples to 16-bit PCM data.
    ///
    /// Float samples are expected in the range [-1.0, 1.0] and are clamped
    /// before conversion to prevent overflow.
    ///
    /// - Parameter samples: Interleaved stereo Float32 samples.
    /// - Returns: Raw 16-bit little-endian PCM data.
    public func convertToInt16PCM(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16Value = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: &int16Value) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Resamples a mono audio buffer using linear interpolation.
    ///
    /// - Parameters:
    ///   - samples: The input mono samples at the source sample rate.
    ///   - sourceSampleRate: The sample rate of the input data.
    /// - Returns: Resampled samples at the target sample rate.
    public func resample(_ samples: [Float], from sourceSampleRate: Double) -> [Float] {
        guard sourceSampleRate != targetSampleRate, !samples.isEmpty else {
            return samples
        }

        let ratio = targetSampleRate / sourceSampleRate
        let outputCount = Int(Double(samples.count) * ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for i in 0 ..< outputCount {
            let sourceIndex = Double(i) / ratio
            let index = Int(sourceIndex)
            let fraction = Float(sourceIndex - Double(index))

            if index + 1 < samples.count {
                output[i] = samples[index] * (1 - fraction) + samples[index + 1] * fraction
            } else if index < samples.count {
                output[i] = samples[index]
            }
        }

        return output
    }

    /// Resamples interleaved stereo audio using linear interpolation.
    ///
    /// Each channel is resampled independently to preserve the stereo image.
    ///
    /// - Parameters:
    ///   - samples: Interleaved stereo samples [L0, R0, L1, R1, ...].
    ///   - sourceSampleRate: The sample rate of the input data.
    /// - Returns: Resampled interleaved stereo samples at the target sample rate.
    public func resampleStereo(_ samples: [Float], from sourceSampleRate: Double) -> [Float] {
        guard sourceSampleRate != targetSampleRate, !samples.isEmpty else {
            return samples
        }

        let frameCount = samples.count / 2
        let ratio = targetSampleRate / sourceSampleRate
        let outputFrames = Int(Double(frameCount) * ratio)
        guard outputFrames > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputFrames * 2)
        for i in 0 ..< outputFrames {
            let sourceIndex = Double(i) / ratio
            let index = Int(sourceIndex)
            let fraction = Float(sourceIndex - Double(index))

            for ch in 0 ..< 2 {
                if index + 1 < frameCount {
                    output[i * 2 + ch] = samples[index * 2 + ch] * (1 - fraction)
                        + samples[(index + 1) * 2 + ch] * fraction
                } else if index < frameCount {
                    output[i * 2 + ch] = samples[index * 2 + ch]
                }
            }
        }

        return output
    }
}
