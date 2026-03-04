use crate::models::mixing_strategy::MixingStrategy;

/// Pure-math stereo audio mixer and resampler.
///
/// Ports the Swift `StereoMixer` 1:1. All operations work on `&[f32]` buffers
/// with no platform dependencies.
///
/// Stereo output format: Left = mic + system_L, Right = mic + system_R.
/// Mic is mono, mixed into center of stereo field.
/// System audio preserves its natural stereo image.
#[derive(Debug, Clone)]
pub struct StereoMixer {
    pub target_sample_rate: f64,
}

impl StereoMixer {
    pub fn new(target_sample_rate: f64) -> Self {
        Self { target_sample_rate }
    }

    /// Mix mono mic audio with interleaved stereo system audio.
    ///
    /// - `mic`: Mono f32 samples (one per frame).
    /// - `system`: Interleaved stereo f32 samples `[L0, R0, L1, R1, ...]`.
    ///
    /// Returns interleaved stereo: `Left[i] = mic[i] + sys_L[i]`, `Right[i] = mic[i] + sys_R[i]`.
    /// If one source has fewer frames, missing samples are treated as silence.
    pub fn mix_mic_with_stereo_system(&self, mic: &[f32], system: &[f32]) -> Vec<f32> {
        let mic_frames = mic.len();
        let system_frames = system.len() / 2;
        let frame_count = mic_frames.max(system_frames);
        if frame_count == 0 {
            return Vec::new();
        }

        let mut stereo = vec![0.0f32; frame_count * 2];
        for i in 0..frame_count {
            let mic_sample = if i < mic_frames { mic[i] } else { 0.0 };
            let sys_l = if i * 2 < system.len() { system[i * 2] } else { 0.0 };
            let sys_r = if i * 2 + 1 < system.len() {
                system[i * 2 + 1]
            } else {
                0.0
            };
            stereo[i * 2] = mic_sample + sys_l;
            stereo[i * 2 + 1] = mic_sample + sys_r;
        }
        stereo
    }

    /// Interleave two mono channels into stereo `[L0, R0, L1, R1, ...]`.
    pub fn interleave(&self, left: &[f32], right: &[f32]) -> Vec<f32> {
        let frame_count = left.len().max(right.len());
        if frame_count == 0 {
            return Vec::new();
        }

        let mut stereo = vec![0.0f32; frame_count * 2];
        for i in 0..frame_count {
            stereo[i * 2] = if i < left.len() { left[i] } else { 0.0 };
            stereo[i * 2 + 1] = if i < right.len() { right[i] } else { 0.0 };
        }
        stereo
    }

    /// Convert f32 samples `[-1.0, 1.0]` to 16-bit PCM (little-endian bytes).
    ///
    /// Clamps out-of-range values. Output length = `samples.len() * 2` bytes.
    pub fn convert_to_int16_pcm(&self, samples: &[f32]) -> Vec<u8> {
        let mut data = Vec::with_capacity(samples.len() * 2);
        for &sample in samples {
            let clamped = sample.clamp(-1.0, 1.0);
            let int16_value = (clamped * i16::MAX as f32) as i16;
            data.extend_from_slice(&int16_value.to_le_bytes());
        }
        data
    }

    /// Linear interpolation resampling for mono audio.
    ///
    /// Resamples from `source_sample_rate` to `self.target_sample_rate`.
    /// Returns input unchanged if rates match.
    pub fn resample(&self, samples: &[f32], source_sample_rate: f64) -> Vec<f32> {
        if (source_sample_rate - self.target_sample_rate).abs() < 0.01 || samples.is_empty() {
            return samples.to_vec();
        }

        let ratio = self.target_sample_rate / source_sample_rate;
        let output_count = (samples.len() as f64 * ratio) as usize;
        if output_count == 0 {
            return Vec::new();
        }

        let mut output = vec![0.0f32; output_count];
        for (i, sample) in output.iter_mut().enumerate() {
            let source_index = i as f64 / ratio;
            let index = source_index as usize;
            let fraction = (source_index - index as f64) as f32;

            if index + 1 < samples.len() {
                *sample = samples[index] * (1.0 - fraction) + samples[index + 1] * fraction;
            } else if index < samples.len() {
                *sample = samples[index];
            }
        }
        output
    }

    /// Linear interpolation resampling for interleaved stereo audio.
    ///
    /// Input: `[L0, R0, L1, R1, ...]` at `source_sample_rate`.
    /// Output: `[L0, R0, L1, R1, ...]` at `self.target_sample_rate`.
    pub fn resample_stereo(&self, samples: &[f32], source_sample_rate: f64) -> Vec<f32> {
        if (source_sample_rate - self.target_sample_rate).abs() < 0.01 || samples.is_empty() {
            return samples.to_vec();
        }

        let frame_count = samples.len() / 2;
        let ratio = self.target_sample_rate / source_sample_rate;
        let output_frames = (frame_count as f64 * ratio) as usize;
        if output_frames == 0 {
            return Vec::new();
        }

        let mut output = vec![0.0f32; output_frames * 2];
        for i in 0..output_frames {
            let source_index = i as f64 / ratio;
            let index = source_index as usize;
            let fraction = (source_index - index as f64) as f32;

            for ch in 0..2usize {
                if index + 1 < frame_count {
                    output[i * 2 + ch] =
                        samples[index * 2 + ch] * (1.0 - fraction) + samples[(index + 1) * 2 + ch] * fraction;
                } else if index < frame_count {
                    output[i * 2 + ch] = samples[index * 2 + ch];
                }
            }
        }
        output
    }

    /// Compute RMS level of samples (0.0–1.0 range for normalized audio).
    pub fn rms_level(samples: &[f32]) -> f32 {
        if samples.is_empty() {
            return 0.0;
        }
        let sum_sq: f32 = samples.iter().map(|s| s * s).sum();
        (sum_sq / samples.len() as f32).sqrt()
    }

    /// Compute peak absolute level of samples.
    pub fn peak_level(samples: &[f32]) -> f32 {
        samples.iter().map(|s| s.abs()).fold(0.0f32, f32::max)
    }

    /// Mixes mic and system audio according to the specified strategy.
    ///
    /// This is the preferred entry point. `mix_mic_with_stereo_system` is kept
    /// for backward compatibility but prefer this method.
    pub fn mix(&self, mic: &[f32], system: &[f32], strategy: &MixingStrategy) -> Vec<f32> {
        match strategy {
            MixingStrategy::Blended | MixingStrategy::Multichannel => {
                self.mix_mic_with_stereo_system(mic, system)
            }
            MixingStrategy::Separated => self.separate_channels(mic, system),
        }
    }

    /// Produces separated-channel stereo: Left = mic, Right = system mono-fold.
    ///
    /// - Left[i]  = mic[i] (zero-padded when mic is shorter)
    /// - Right[i] = (system[2*i] + system[2*i+1]) / 2  (mono-fold preserving both channels)
    ///
    /// Frame count = max(mic.len(), system.len() / 2).
    pub fn separate_channels(&self, mic: &[f32], system: &[f32]) -> Vec<f32> {
        let mic_frames = mic.len();
        let system_frames = system.len() / 2;
        let frame_count = mic_frames.max(system_frames);
        if frame_count == 0 {
            return Vec::new();
        }

        let mut stereo = vec![0.0f32; frame_count * 2];
        for i in 0..frame_count {
            stereo[i * 2] = if i < mic_frames { mic[i] } else { 0.0 }; // Left = mic
            let sys_l = if i * 2 < system.len() { system[i * 2] } else { 0.0 };
            let sys_r = if i * 2 + 1 < system.len() { system[i * 2 + 1] } else { 0.0 };
            stereo[i * 2 + 1] = (sys_l + sys_r) / 2.0; // Right = mono-fold
        }
        stereo
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mix_mic_with_stereo_system_basic() {
        let mixer = StereoMixer::new(48000.0);
        let mic = [0.5, 0.3];
        let system = [0.1, 0.2, 0.3, 0.4];

        let result = mixer.mix_mic_with_stereo_system(&mic, &system);

        assert_eq!(result.len(), 4);
        assert!((result[0] - 0.6).abs() < 1e-6); // L: 0.5 + 0.1
        assert!((result[1] - 0.7).abs() < 1e-6); // R: 0.5 + 0.2
        assert!((result[2] - 0.6).abs() < 1e-6); // L: 0.3 + 0.3
        assert!((result[3] - 0.7).abs() < 1e-6); // R: 0.3 + 0.4
    }

    #[test]
    fn mix_mic_longer_than_system() {
        let mixer = StereoMixer::new(48000.0);
        let mic = [0.5, 0.3, 0.1];
        let system = [0.1, 0.2]; // 1 stereo frame

        let result = mixer.mix_mic_with_stereo_system(&mic, &system);

        assert_eq!(result.len(), 6); // 3 frames
                                     // Frame 2 and 3: system is zero-padded
        assert!((result[4] - 0.1).abs() < 1e-6); // L: 0.1 + 0.0
        assert!((result[5] - 0.1).abs() < 1e-6); // R: 0.1 + 0.0
    }

    #[test]
    fn mix_empty_inputs() {
        let mixer = StereoMixer::new(48000.0);
        assert!(mixer.mix_mic_with_stereo_system(&[], &[]).is_empty());
    }

    #[test]
    fn interleave_basic() {
        let mixer = StereoMixer::new(48000.0);
        let left = [1.0, 2.0, 3.0];
        let right = [4.0, 5.0, 6.0];

        let result = mixer.interleave(&left, &right);

        assert_eq!(result, vec![1.0, 4.0, 2.0, 5.0, 3.0, 6.0]);
    }

    #[test]
    fn interleave_unequal_lengths() {
        let mixer = StereoMixer::new(48000.0);
        let left = [1.0, 2.0];
        let right = [4.0, 5.0, 6.0];

        let result = mixer.interleave(&left, &right);

        assert_eq!(result.len(), 6);
        assert_eq!(result[4], 0.0); // left zero-padded
        assert_eq!(result[5], 6.0);
    }

    #[test]
    fn convert_to_int16_pcm() {
        let mixer = StereoMixer::new(48000.0);
        let samples = [0.0f32, 1.0, -1.0, 0.5];

        let pcm = mixer.convert_to_int16_pcm(&samples);

        assert_eq!(pcm.len(), 8); // 4 samples * 2 bytes each

        // 0.0 → 0
        let v0 = i16::from_le_bytes([pcm[0], pcm[1]]);
        assert_eq!(v0, 0);

        // 1.0 → 32767 (i16::MAX)
        let v1 = i16::from_le_bytes([pcm[2], pcm[3]]);
        assert_eq!(v1, i16::MAX);

        // -1.0 → -32767 (not -32768 due to clamping math)
        let v2 = i16::from_le_bytes([pcm[4], pcm[5]]);
        assert_eq!(v2, -i16::MAX);
    }

    #[test]
    fn convert_clamps_out_of_range() {
        let mixer = StereoMixer::new(48000.0);
        let samples = [2.0f32, -3.0];

        let pcm = mixer.convert_to_int16_pcm(&samples);

        let v0 = i16::from_le_bytes([pcm[0], pcm[1]]);
        assert_eq!(v0, i16::MAX);
        let v1 = i16::from_le_bytes([pcm[2], pcm[3]]);
        assert_eq!(v1, -i16::MAX);
    }

    #[test]
    fn resample_same_rate_is_passthrough() {
        let mixer = StereoMixer::new(48000.0);
        let samples = vec![1.0, 2.0, 3.0];

        let result = mixer.resample(&samples, 48000.0);

        assert_eq!(result, samples);
    }

    #[test]
    fn resample_upsample_2x() {
        let mixer = StereoMixer::new(48000.0);
        let samples = vec![0.0, 1.0];

        let result = mixer.resample(&samples, 24000.0);

        // 2 samples at 24kHz → 4 samples at 48kHz
        assert_eq!(result.len(), 4);
        assert!((result[0] - 0.0).abs() < 0.01);
        // Midpoint should be ~0.5 (linear interpolation)
        assert!((result[1] - 0.5).abs() < 0.1);
    }

    #[test]
    fn resample_downsample() {
        let mixer = StereoMixer::new(24000.0);
        let samples: Vec<f32> = (0..100).map(|i| i as f32 / 100.0).collect();

        let result = mixer.resample(&samples, 48000.0);

        // 100 samples at 48kHz → ~50 at 24kHz
        assert_eq!(result.len(), 50);
    }

    #[test]
    fn resample_stereo_same_rate() {
        let mixer = StereoMixer::new(48000.0);
        let samples = vec![1.0, 2.0, 3.0, 4.0];

        let result = mixer.resample_stereo(&samples, 48000.0);

        assert_eq!(result, samples);
    }

    #[test]
    fn rms_level_silence() {
        assert_eq!(StereoMixer::rms_level(&[0.0, 0.0, 0.0]), 0.0);
    }

    #[test]
    fn rms_level_full_scale() {
        let rms = StereoMixer::rms_level(&[1.0, 1.0, 1.0]);
        assert!((rms - 1.0).abs() < 1e-6);
    }

    #[test]
    fn peak_level_basic() {
        assert!((StereoMixer::peak_level(&[0.1, -0.5, 0.3]) - 0.5).abs() < 1e-6);
    }

    #[test]
    fn separate_channels_left_is_mic_only() {
        let mixer = StereoMixer::new(48000.0);
        let mic = [0.5f32, 0.3];
        let system = [0.1f32, 0.2, 0.1, 0.2];
        let result = mixer.separate_channels(&mic, &system);
        assert!((result[0] - 0.5).abs() < 1e-6); // frame 0, L = mic
        assert!((result[2] - 0.3).abs() < 1e-6); // frame 1, L = mic
    }

    #[test]
    fn separate_channels_right_is_system_mono_fold_not_l_only() {
        let mixer = StereoMixer::new(48000.0);
        let mic = [0.0f32, 0.0];
        let system = [0.8f32, 0.4, 0.8, 0.4];
        let result = mixer.separate_channels(&mic, &system);
        // Right = (0.8 + 0.4) / 2 = 0.6, NOT 0.8 (L only)
        assert!((result[1] - 0.6).abs() < 1e-6);
        assert!((result[3] - 0.6).abs() < 1e-6);
    }

    #[test]
    fn separate_channels_silent_mic_left_is_zero() {
        let mixer = StereoMixer::new(48000.0);
        let mic = [0.0f32, 0.0];
        let system = [0.5f32, 0.5, 0.5, 0.5];
        let result = mixer.separate_channels(&mic, &system);
        assert!(result[0].abs() < 1e-6);
        assert!(result[2].abs() < 1e-6);
    }

    #[test]
    fn separate_channels_silent_system_right_is_zero() {
        let mixer = StereoMixer::new(48000.0);
        let mic = [0.5f32, 0.3];
        let system = [0.0f32, 0.0, 0.0, 0.0];
        let result = mixer.separate_channels(&mic, &system);
        assert!(result[1].abs() < 1e-6);
        assert!(result[3].abs() < 1e-6);
    }

    #[test]
    fn separate_channels_mic_longer_zero_pads_right() {
        let mixer = StereoMixer::new(48000.0);
        let mic = [0.5f32, 0.3, 0.1];
        let system = [0.2f32, 0.2]; // 1 stereo frame
        let result = mixer.separate_channels(&mic, &system);
        assert_eq!(result.len(), 6); // 3 frames
        // frame 2: L = mic[2] = 0.1, R = 0 (system exhausted)
        assert!((result[4] - 0.1).abs() < 1e-6);
        assert!(result[5].abs() < 1e-6);
    }

    #[test]
    fn separate_channels_system_longer_zero_pads_left() {
        let mixer = StereoMixer::new(48000.0);
        let mic = [0.5f32]; // 1 frame
        let system = [0.2f32, 0.4, 0.6, 0.8, 0.2, 0.4]; // 3 stereo frames
        let result = mixer.separate_channels(&mic, &system);
        assert_eq!(result.len(), 6); // 3 frames
        // frame 1: L = 0 (mic exhausted), R = (0.6 + 0.8) / 2 = 0.7
        assert!(result[2].abs() < 1e-6);
        assert!((result[3] - 0.7).abs() < 1e-6);
    }

    #[test]
    fn separate_channels_both_empty() {
        let mixer = StereoMixer::new(48000.0);
        assert!(mixer.separate_channels(&[], &[]).is_empty());
    }

    #[test]
    fn mix_blended_matches_legacy() {
        let mixer = StereoMixer::new(48000.0);
        let mic = [0.5f32, 0.3];
        let system = [0.1f32, 0.2, 0.3, 0.4];
        let legacy = mixer.mix_mic_with_stereo_system(&mic, &system);
        let new_method = mixer.mix(&mic, &system, &MixingStrategy::Blended);
        assert_eq!(legacy, new_method);
    }

    #[test]
    fn mix_separated_no_mic_in_right_channel() {
        let mixer = StereoMixer::new(48000.0);
        let mic = [0.5f32, 0.3];
        let system = [0.0f32, 0.0, 0.0, 0.0];
        let result = mixer.mix(&mic, &system, &MixingStrategy::Separated);
        assert!(result[1].abs() < 1e-6);
        assert!(result[3].abs() < 1e-6);
    }
}
