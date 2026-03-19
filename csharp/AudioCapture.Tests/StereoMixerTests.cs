using AudioCapture.Models;
using AudioCapture.Processing;
using Xunit;

namespace AudioCapture.Tests;

public class StereoMixerTests
{
    private readonly StereoMixer _mixer = new();

    [Fact]
    public void Blended_MicAddedToBothChannels()
    {
        float[] mic = [0.5f];
        float[] system = [0.3f, 0.4f]; // L=0.3, R=0.4

        var result = _mixer.MixBlended(mic, system);

        Assert.Equal(2, result.Length);
        Assert.Equal(0.8f, result[0], 0.001f); // L = 0.5 + 0.3
        Assert.Equal(0.9f, result[1], 0.001f); // R = 0.5 + 0.4
    }

    [Fact]
    public void Separated_MicOnLeft_SystemMonoFoldOnRight()
    {
        float[] mic = [0.5f];
        float[] system = [0.3f, 0.7f]; // L=0.3, R=0.7

        var result = _mixer.MixSeparated(mic, system);

        Assert.Equal(2, result.Length);
        Assert.Equal(0.5f, result[0], 0.001f);  // L = mic
        Assert.Equal(0.5f, result[1], 0.001f);  // R = (0.3+0.7)/2 = 0.5
    }

    [Fact]
    public void Mix_EmptyInputs_ReturnsEmpty()
    {
        var result = _mixer.Mix([], [], MixingStrategy.Blended);
        Assert.Empty(result);
    }

    [Fact]
    public void Blended_MicShorter_ZeroPadded()
    {
        float[] mic = [0.5f]; // 1 frame
        float[] system = [0.1f, 0.2f, 0.3f, 0.4f]; // 2 frames

        var result = _mixer.MixBlended(mic, system);

        Assert.Equal(4, result.Length); // 2 frames * 2 channels
        // Frame 0: mic present
        Assert.Equal(0.6f, result[0], 0.001f); // L = 0.5 + 0.1
        Assert.Equal(0.7f, result[1], 0.001f); // R = 0.5 + 0.2
        // Frame 1: mic = 0
        Assert.Equal(0.3f, result[2], 0.001f); // L = 0 + 0.3
        Assert.Equal(0.4f, result[3], 0.001f); // R = 0 + 0.4
    }

    [Fact]
    public void Blended_SystemShorter_ZeroPadded()
    {
        float[] mic = [0.5f, 0.6f]; // 2 frames
        float[] system = [0.1f, 0.2f]; // 1 frame

        var result = _mixer.MixBlended(mic, system);

        Assert.Equal(4, result.Length);
        // Frame 0: both present
        Assert.Equal(0.6f, result[0], 0.001f);
        Assert.Equal(0.7f, result[1], 0.001f);
        // Frame 1: system = 0
        Assert.Equal(0.6f, result[2], 0.001f);
        Assert.Equal(0.6f, result[3], 0.001f);
    }

    [Fact]
    public void Silence_ReturnsAllZeros()
    {
        float[] mic = [0f, 0f];
        float[] system = [0f, 0f, 0f, 0f];

        var result = _mixer.MixBlended(mic, system);

        Assert.All(result, sample => Assert.Equal(0f, sample));
    }

    [Fact]
    public void ConvertToInt16Pcm_ClampsAndConverts()
    {
        float[] samples = [0f, 1f, -1f, 1.5f, -1.5f];
        var pcm = StereoMixer.ConvertToInt16Pcm(samples);

        Assert.Equal(10, pcm.Length); // 5 samples * 2 bytes

        // Sample 0: silence
        Assert.Equal(0, BitConverter.ToInt16(pcm, 0));
        // Sample 1: max
        Assert.Equal(short.MaxValue, BitConverter.ToInt16(pcm, 2));
        // Sample 2: min
        Assert.Equal(-short.MaxValue, BitConverter.ToInt16(pcm, 4));
        // Sample 3: clamped to max
        Assert.Equal(short.MaxValue, BitConverter.ToInt16(pcm, 6));
        // Sample 4: clamped to min
        Assert.Equal(-short.MaxValue, BitConverter.ToInt16(pcm, 8));
    }

    [Fact]
    public void Mix_WithStrategyParameter_DispatchesCorrectly()
    {
        float[] mic = [0.5f];
        float[] system = [0.3f, 0.7f];

        var blended = _mixer.Mix(mic, system, MixingStrategy.Blended);
        var separated = _mixer.Mix(mic, system, MixingStrategy.Separated);

        // Blended: L = 0.5+0.3=0.8, R = 0.5+0.7=1.2
        Assert.Equal(0.8f, blended[0], 0.001f);
        // Separated: L = 0.5, R = (0.3+0.7)/2 = 0.5
        Assert.Equal(0.5f, separated[0], 0.001f);
        Assert.Equal(0.5f, separated[1], 0.001f);
    }
}
