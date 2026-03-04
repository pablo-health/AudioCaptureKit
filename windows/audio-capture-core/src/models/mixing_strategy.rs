use serde::{Deserialize, Serialize};

/// Controls how microphone and system audio are combined into the output WAV file.
///
/// Mirrors Swift `MixingStrategy` 1:1.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MixingStrategy {
    /// Mic is mixed into both stereo channels alongside system audio.
    /// Left = mic + system_L, Right = mic + system_R.
    /// This is the default and matches original behavior.
    #[default]
    Blended,

    /// Mic and system occupy separate stereo channels.
    /// Left (Ch 1) = mic only.
    /// Right (Ch 2) = system audio mono-folded as (L + R) / 2.
    Separated,

    /// Reserved for future multi-mic configurations.
    /// Currently behaves identically to Blended.
    Multichannel,
}
