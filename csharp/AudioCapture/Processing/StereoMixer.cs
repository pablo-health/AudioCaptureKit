using AudioCapture.Models;

namespace AudioCapture.Processing;

/// <summary>
/// Mixes mono mic audio with stereo system audio. Mirrors Swift StereoMixer.
/// </summary>
public sealed class StereoMixer
{
    /// <summary>
    /// Mixes mic and system audio according to the specified strategy.
    /// </summary>
    /// <param name="mic">Mono mic samples (Float32).</param>
    /// <param name="system">Interleaved stereo system samples [L0, R0, L1, R1, ...].</param>
    /// <param name="strategy">Mixing strategy.</param>
    /// <returns>Interleaved stereo Float32 samples.</returns>
    public float[] Mix(float[] mic, float[] system, MixingStrategy strategy)
    {
        return strategy switch
        {
            MixingStrategy.Separated => MixSeparated(mic, system),
            _ => MixBlended(mic, system),
        };
    }

    /// <summary>
    /// Blended: L = mic + sys_L, R = mic + sys_R
    /// </summary>
    public float[] MixBlended(float[] mic, float[] system)
    {
        int micFrames = mic.Length;
        int systemFrames = system.Length / 2;
        int frameCount = Math.Max(micFrames, systemFrames);
        if (frameCount == 0) return [];

        var stereo = new float[frameCount * 2];
        for (int i = 0; i < frameCount; i++)
        {
            float micSample = i < micFrames ? mic[i] : 0f;
            float sysL = (i * 2) < system.Length ? system[i * 2] : 0f;
            float sysR = (i * 2 + 1) < system.Length ? system[i * 2 + 1] : 0f;
            stereo[i * 2] = micSample + sysL;
            stereo[i * 2 + 1] = micSample + sysR;
        }
        return stereo;
    }

    /// <summary>
    /// Separated: L = mic, R = (sys_L + sys_R) / 2
    /// </summary>
    public float[] MixSeparated(float[] mic, float[] system)
    {
        int micFrames = mic.Length;
        int systemFrames = system.Length / 2;
        int frameCount = Math.Max(micFrames, systemFrames);
        if (frameCount == 0) return [];

        var stereo = new float[frameCount * 2];
        for (int i = 0; i < frameCount; i++)
        {
            stereo[i * 2] = i < micFrames ? mic[i] : 0f;
            float sysL = (i * 2) < system.Length ? system[i * 2] : 0f;
            float sysR = (i * 2 + 1) < system.Length ? system[i * 2 + 1] : 0f;
            stereo[i * 2 + 1] = (sysL + sysR) / 2f;
        }
        return stereo;
    }

    /// <summary>
    /// Converts interleaved Float32 samples to 16-bit little-endian PCM.
    /// </summary>
    public static byte[] ConvertToInt16Pcm(float[] samples)
    {
        var data = new byte[samples.Length * 2];
        for (int i = 0; i < samples.Length; i++)
        {
            float clamped = Math.Clamp(samples[i], -1f, 1f);
            short int16 = (short)(clamped * short.MaxValue);
            data[i * 2] = (byte)(int16 & 0xFF);
            data[i * 2 + 1] = (byte)((int16 >> 8) & 0xFF);
        }
        return data;
    }
}
