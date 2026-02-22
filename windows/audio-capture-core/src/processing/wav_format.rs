/// WAV file format utilities.
///
/// Generates standard 44-byte RIFF WAV headers and provides helpers
/// for updating header fields after recording completes.
///
/// Ports Swift's `AudioFormatConverter.generateWAVHeader` byte-for-byte.
/// Size of the standard WAV RIFF header in bytes.
pub const WAV_HEADER_SIZE: usize = 44;

/// Generate a 44-byte WAV RIFF header.
///
/// Format: PCM (format code 1), little-endian.
///
/// Layout:
/// ```text
/// [0-3]    "RIFF"
/// [4-7]    file size - 8 (placeholder: 36 + data_size)
/// [8-11]   "WAVE"
/// [12-15]  "fmt "
/// [16-19]  16 (PCM format chunk size)
/// [20-21]  1 (PCM format code)
/// [22-23]  channels
/// [24-27]  sample_rate
/// [28-31]  byte_rate = sample_rate * channels * bit_depth / 8
/// [32-33]  block_align = channels * bit_depth / 8
/// [34-35]  bit_depth
/// [36-39]  "data"
/// [40-43]  data_size
/// ```
pub fn generate_wav_header(sample_rate: u32, bit_depth: u16, channels: u16, data_size: u32) -> [u8; WAV_HEADER_SIZE] {
    let byte_rate = sample_rate * channels as u32 * bit_depth as u32 / 8;
    let block_align = channels * bit_depth / 8;
    let chunk_size = 36 + data_size;

    let mut header = [0u8; WAV_HEADER_SIZE];

    // RIFF chunk descriptor
    header[0..4].copy_from_slice(b"RIFF");
    header[4..8].copy_from_slice(&chunk_size.to_le_bytes());
    header[8..12].copy_from_slice(b"WAVE");

    // fmt sub-chunk
    header[12..16].copy_from_slice(b"fmt ");
    header[16..20].copy_from_slice(&16u32.to_le_bytes()); // PCM format size
    header[20..22].copy_from_slice(&1u16.to_le_bytes()); // PCM format code
    header[22..24].copy_from_slice(&channels.to_le_bytes());
    header[24..28].copy_from_slice(&sample_rate.to_le_bytes());
    header[28..32].copy_from_slice(&byte_rate.to_le_bytes());
    header[32..34].copy_from_slice(&block_align.to_le_bytes());
    header[34..36].copy_from_slice(&bit_depth.to_le_bytes());

    // data sub-chunk
    header[36..40].copy_from_slice(b"data");
    header[40..44].copy_from_slice(&data_size.to_le_bytes());

    header
}

/// Patch the file-size field at offset 4 (RIFF chunk size = file_size - 8).
pub fn patch_file_size(header: &mut [u8], total_file_size: u64) {
    let chunk_size = (total_file_size - 8) as u32;
    header[4..8].copy_from_slice(&chunk_size.to_le_bytes());
}

/// Patch the data-size field at offset 40.
pub fn patch_data_size(header: &mut [u8], data_size: u64) {
    let data_size_u32 = data_size as u32;
    header[40..44].copy_from_slice(&data_size_u32.to_le_bytes());
}

/// Patch sample rate (offset 24), byte rate (offset 28), and block align (offset 32).
///
/// Used when Bluetooth HFP negotiation changes the actual sample rate.
pub fn patch_sample_rate(header: &mut [u8], sample_rate: u32, channels: u16, bit_depth: u16) {
    let byte_rate = sample_rate * channels as u32 * bit_depth as u32 / 8;
    let block_align = channels * bit_depth / 8;

    header[24..28].copy_from_slice(&sample_rate.to_le_bytes());
    header[28..32].copy_from_slice(&byte_rate.to_le_bytes());
    header[32..34].copy_from_slice(&block_align.to_le_bytes());
}

/// Downmix interleaved multi-channel audio to mono by averaging channels per frame.
pub fn downmix_to_mono(samples: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return samples.to_vec();
    }
    let frame_count = samples.len() / channels;
    let scale = 1.0 / channels as f32;
    let mut mono = Vec::with_capacity(frame_count);
    for frame in 0..frame_count {
        let mut sum = 0.0f32;
        for ch in 0..channels {
            sum += samples[frame * channels + ch];
        }
        mono.push(sum * scale);
    }
    mono
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_size_is_44_bytes() {
        let header = generate_wav_header(48000, 16, 2, 0);
        assert_eq!(header.len(), 44);
    }

    #[test]
    fn header_riff_magic() {
        let header = generate_wav_header(48000, 16, 2, 0);
        assert_eq!(&header[0..4], b"RIFF");
        assert_eq!(&header[8..12], b"WAVE");
        assert_eq!(&header[12..16], b"fmt ");
        assert_eq!(&header[36..40], b"data");
    }

    #[test]
    fn header_pcm_format() {
        let header = generate_wav_header(48000, 16, 2, 0);
        // Format code = 1 (PCM)
        assert_eq!(u16::from_le_bytes([header[20], header[21]]), 1);
        // fmt chunk size = 16
        assert_eq!(u32::from_le_bytes([header[16], header[17], header[18], header[19]]), 16);
    }

    #[test]
    fn header_48khz_stereo_16bit() {
        let header = generate_wav_header(48000, 16, 2, 9600);

        let channels = u16::from_le_bytes([header[22], header[23]]);
        assert_eq!(channels, 2);

        let sample_rate = u32::from_le_bytes([header[24], header[25], header[26], header[27]]);
        assert_eq!(sample_rate, 48000);

        let byte_rate = u32::from_le_bytes([header[28], header[29], header[30], header[31]]);
        assert_eq!(byte_rate, 192000); // 48000 * 2 * 16/8

        let block_align = u16::from_le_bytes([header[32], header[33]]);
        assert_eq!(block_align, 4); // 2 * 16/8

        let bit_depth = u16::from_le_bytes([header[34], header[35]]);
        assert_eq!(bit_depth, 16);

        let data_size = u32::from_le_bytes([header[40], header[41], header[42], header[43]]);
        assert_eq!(data_size, 9600);

        let chunk_size = u32::from_le_bytes([header[4], header[5], header[6], header[7]]);
        assert_eq!(chunk_size, 36 + 9600);
    }

    #[test]
    fn patch_sizes() {
        let mut header = generate_wav_header(48000, 16, 2, 0);

        patch_data_size(&mut header, 19200);
        let data_size = u32::from_le_bytes([header[40], header[41], header[42], header[43]]);
        assert_eq!(data_size, 19200);

        patch_file_size(&mut header, 19200 + 44);
        let chunk_size = u32::from_le_bytes([header[4], header[5], header[6], header[7]]);
        assert_eq!(chunk_size, 19200 + 36);
    }

    #[test]
    fn patch_sample_rate_updates_derived_fields() {
        let mut header = generate_wav_header(48000, 16, 2, 0);
        patch_sample_rate(&mut header, 16000, 2, 16);

        let sample_rate = u32::from_le_bytes([header[24], header[25], header[26], header[27]]);
        assert_eq!(sample_rate, 16000);

        let byte_rate = u32::from_le_bytes([header[28], header[29], header[30], header[31]]);
        assert_eq!(byte_rate, 64000); // 16000 * 2 * 2
    }

    #[test]
    fn downmix_stereo_to_mono() {
        let stereo = [0.2, 0.8, 0.4, 0.6];
        let mono = downmix_to_mono(&stereo, 2);
        assert_eq!(mono.len(), 2);
        assert!((mono[0] - 0.5).abs() < 1e-6);
        assert!((mono[1] - 0.5).abs() < 1e-6);
    }

    #[test]
    fn downmix_mono_passthrough() {
        let samples = vec![0.1, 0.2, 0.3];
        let result = downmix_to_mono(&samples, 1);
        assert_eq!(result, samples);
    }
}
