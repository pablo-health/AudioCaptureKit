import Foundation

/// Controls how microphone and system audio are combined into the output WAV file.
public enum MixingStrategy: Sendable, Codable {
    /// Mic is mixed into both stereo channels alongside system audio.
    /// - Left:  mic + system_L
    /// - Right: mic + system_R
    /// This is the default and matches the original AudioCaptureKit behavior.
    case blended

    /// Mic and system audio occupy separate stereo channels with no blending.
    /// - Left (Ch 1):  mic only (mono mic signal)
    /// - Right (Ch 2): system audio, mono-folded as (system_L + system_R) / 2
    case separated

    /// Reserved for future 3-channel multi-mic configurations.
    /// Currently behaves identically to ``separated``.
    case multichannel
}
