using AudioCapture.Processing;
using Xunit;

namespace AudioCapture.Tests;

/// <summary>
/// Covers the reconciliation between a loopback endpoint's mix format and the
/// configured capture shape.
///
/// These are deterministic by construction — samples in, samples out, no timers
/// and no wall clock — which is the point: the session-level tests inject
/// fixtures that are 48 kHz stereo by construction, so they can never exercise a
/// mismatched endpoint. This is the only place the conversion itself is proven.
/// </summary>
public class SystemAudioNormalizerTests
{
    private const int Target = 48000;

    /// <summary>Interleaved stereo sine, amplitude 0.5 — a signal RMS can be compared across a resample.</summary>
    private static float[] StereoSine(int frames, int sampleRate, double frequency = 440)
    {
        var samples = new float[frames * 2];
        for (int i = 0; i < frames; i++)
        {
            var value = (float)(Math.Sin(2 * Math.PI * frequency * i / sampleRate) * 0.5);
            samples[i * 2] = samples[i * 2 + 1] = value;
        }
        return samples;
    }

    private static double Rms(float[] samples)
    {
        if (samples.Length == 0) return 0;
        double sum = 0;
        foreach (var s in samples) sum += (double)s * s;
        return Math.Sqrt(sum / samples.Length);
    }

    [Fact]
    public void MatchingEndpoint_IsPassthrough()
    {
        var normalizer = new SystemAudioNormalizer(Target, 2, Target);

        Assert.True(normalizer.IsPassthrough);

        // The common case: the same buffer comes back untouched, no resampler in play.
        var input = StereoSine(480, Target);
        Assert.Same(input, normalizer.Normalize(input));
    }

    [Fact]
    public void MismatchedRate_IsNotPassthrough()
    {
        Assert.False(new SystemAudioNormalizer(44100, 2, Target).IsPassthrough);
    }

    [Fact]
    public void MonoEndpoint_IsNotPassthroughEvenAtTargetRate()
    {
        // Right rate, wrong shape: StereoMixer would read mono frames as stereo.
        Assert.False(new SystemAudioNormalizer(Target, 1, Target).IsPassthrough);
    }

    [Fact]
    public void MonoEndpoint_IsDuplicatedToBothLegs()
    {
        var normalizer = new SystemAudioNormalizer(Target, 1, Target);

        var output = normalizer.Normalize([0.25f, -0.5f, 0.75f]);

        Assert.Equal([0.25f, 0.25f, -0.5f, -0.5f, 0.75f, 0.75f], output);
    }

    [Fact]
    public void MultiChannelEndpoint_IsFoldedToStereoWithoutLosingFrames()
    {
        // A 5.1 endpoint: 6 samples per frame. Reading those as stereo is the
        // "garbled" failure — the fold has to collapse them per frame, not reshape.
        var normalizer = new SystemAudioNormalizer(Target, 6, Target);

        // Two frames; each frame averages to a known value.
        float[] input = [
            0.6f, 0.6f, 0.6f, 0.6f, 0.6f, 0.6f,
            -0.3f, -0.3f, -0.3f, -0.3f, -0.3f, -0.3f,
        ];
        var output = normalizer.Normalize(input);

        Assert.Equal(4, output.Length);
        Assert.Equal(0.6f, output[0], 0.0001f);
        Assert.Equal(0.6f, output[1], 0.0001f);
        Assert.Equal(-0.3f, output[2], 0.0001f);
        Assert.Equal(-0.3f, output[3], 0.0001f);
    }

    [Fact]
    public void MultiChannelEndpoint_KeepsSpeechCarriedOnASingleChannel()
    {
        // Dialogue often sits on the centre channel alone. Taking the first pair
        // would drop it entirely; averaging keeps it, quieter but present.
        var normalizer = new SystemAudioNormalizer(Target, 6, Target);

        // One frame, signal only on channel 2 (centre).
        var output = normalizer.Normalize([0f, 0f, 0.6f, 0f, 0f, 0f]);

        Assert.Equal(2, output.Length);
        Assert.True(output[0] > 0, "centre-channel speech should survive the fold");
        Assert.Equal(0.1f, output[0], 0.0001f); // 0.6 / 6
    }

    [Fact]
    public void MismatchedRate_YieldsTargetRateFrameCountOverAStream()
    {
        // The load-bearing assertion. A 44.1 kHz endpoint feeding a 48 kHz-stamped
        // sidecar is the bug this exists to kill: one wall-clock second of endpoint
        // audio must leave as one wall-clock second of target-rate audio, or the
        // recording plays fast.
        var normalizer = new SystemAudioNormalizer(44100, 2, Target);

        // A second of audio, pushed in 10 ms chunks the way a capture callback would.
        var chunkFrames = 441;
        var total = 0;
        for (int i = 0; i < 100; i++)
            total += normalizer.Normalize(StereoSine(chunkFrames, 44100)).Length / 2;

        // Within 1%: the resampler's filter latency holds back a few frames at the
        // head, which is immaterial over a stream but not exactly zero.
        Assert.InRange(total, Target * 0.99, Target * 1.01);
    }

    [Fact]
    public void MismatchedRate_DoesNotResetPerChunk()
    {
        // If the resampler were rebuilt per call, each chunk would re-pay filter
        // latency and the stream would run progressively short. Compare a single
        // large push against the same audio split fine.
        var oneShot = new SystemAudioNormalizer(44100, 2, Target);
        var chunked = new SystemAudioNormalizer(44100, 2, Target);

        var bulk = oneShot.Normalize(StereoSine(44100, 44100)).Length / 2;

        var streamed = 0;
        for (int i = 0; i < 441; i++)
            streamed += chunked.Normalize(StereoSine(100, 44100)).Length / 2;

        Assert.InRange(streamed, bulk * 0.99, bulk * 1.01);
    }

    [Fact]
    public void Resampling_PreservesSignalRatherThanEmittingSilence()
    {
        // A resample that "succeeds" into silence would still satisfy the frame
        // count, and the harness's RMS liveness gate would then read a dead channel.
        var normalizer = new SystemAudioNormalizer(44100, 2, Target);

        double sumSquares = 0;
        int count = 0;
        for (int i = 0; i < 20; i++)
        {
            var output = normalizer.Normalize(StereoSine(441, 44100));
            foreach (var s in output) { sumSquares += (double)s * s; count++; }
        }

        var outputRms = count == 0 ? 0 : Math.Sqrt(sumSquares / count);
        var inputRms = Rms(StereoSine(441, 44100));

        // A 0.5-amplitude sine sits near 0.354 RMS; resampling shifts it slightly,
        // not by an order of magnitude.
        Assert.InRange(outputRms, inputRms * 0.8, inputRms * 1.2);
    }

    [Fact]
    public void EmptyBuffer_YieldsEmptyWithoutDisturbingResamplerState()
    {
        var normalizer = new SystemAudioNormalizer(44100, 2, Target);

        Assert.Empty(normalizer.Normalize([]));

        // Still converts normally afterwards.
        var total = 0;
        for (int i = 0; i < 100; i++)
            total += normalizer.Normalize(StereoSine(441, 44100)).Length / 2;
        Assert.InRange(total, Target * 0.99, Target * 1.01);
    }

    [Theory]
    [InlineData(0, 2, 48000)]
    [InlineData(44100, 0, 48000)]
    [InlineData(44100, 2, 0)]
    public void NonsenseFormats_AreRejected(int sourceRate, int sourceChannels, int targetRate)
    {
        Assert.Throws<ArgumentOutOfRangeException>(
            () => new SystemAudioNormalizer(sourceRate, sourceChannels, targetRate));
    }
}
