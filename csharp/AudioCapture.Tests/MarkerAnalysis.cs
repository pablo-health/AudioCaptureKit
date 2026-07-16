using System.Diagnostics;
using NAudio.Wave;

namespace AudioCapture.Tests;

/// <summary>
/// Numeric test support for <see cref="SignalGeneratorSoakTests"/>: reading a finalized
/// WAV back into per-channel float samples, detecting the deterministic marker bursts a
/// <see cref="AudioCapture.Capture.SignalGeneratorWaveIn"/> writes into it (via a Goertzel
/// single-frequency detector), and reading process resident memory.
///
/// Pure functions with no dependency on the suite's state — the C# mirror of Swift
/// <c>MarkerAnalysis.swift</c>.
/// </summary>
internal static class MarkerAnalysis
{
    internal sealed record WavChannels(float[] Left, float[] Right, int SampleRate);

    /// <summary>
    /// Reads a finalized WAV into per-channel float samples. Throwing here (rather than
    /// reading garbage) is itself part of the "clean finalize" proof: a truncated or
    /// corrupt header fails the read.
    /// </summary>
    internal static WavChannels ReadWavChannels(string path)
    {
        using var reader = new WaveFileReader(path);
        var channels = reader.WaveFormat.Channels;
        var sampleRate = reader.WaveFormat.SampleRate;

        var left = new List<float>();
        var right = new List<float>();

        // ToSampleProvider normalizes 16-bit PCM to float for us, which is what the
        // detector wants — amplitudes comparable to the synthesized source.
        var provider = reader.ToSampleProvider();
        var buffer = new float[sampleRate * channels];
        int read;
        while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
        {
            for (int i = 0; i + channels - 1 < read; i += channels)
            {
                left.Add(buffer[i]);
                if (channels > 1) right.Add(buffer[i + 1]);
            }
        }

        return new WavChannels([.. left], [.. right], sampleRate);
    }

    /// <summary>
    /// Reads a raw signed-16-bit-LE PCM sidecar, folding to mono.
    ///
    /// <para>Marker timing is asserted against the sidecars rather than the mixed WAV on
    /// purpose. A sidecar holds one source's frames exactly as delivered, so its timeline
    /// is that source's own. The mixed WAV's is not: <see cref="Processing.StereoMixer"/>
    /// pads the shorter channel out to the longer on every mix cycle, so two
    /// independently-clocked sources stretch each other's timelines a little each pass.
    /// The sidecars are also what actually gets uploaded and transcribed, which makes
    /// them the timeline worth defending.</para>
    /// </summary>
    internal static float[] ReadRawPcm(string path, int channels = 1)
    {
        var bytes = File.ReadAllBytes(path);
        var frames = bytes.Length / 2 / channels;
        var samples = new float[frames];
        for (int i = 0; i < frames; i++)
        {
            // Fold channels so a stereo sidecar reduces to one comparable envelope.
            float sum = 0;
            for (int ch = 0; ch < channels; ch++)
            {
                var offset = ((i * channels) + ch) * 2;
                sum += BitConverter.ToInt16(bytes, offset) / (float)short.MaxValue;
            }
            samples[i] = sum / channels;
        }
        return samples;
    }

    /// <summary>
    /// Scans <paramref name="channel"/> for bursts at <paramref name="frequency"/>,
    /// returning each burst's onset time in seconds.
    ///
    /// Uses overlapping Goertzel windows: short enough (10 ms) to localize onset well
    /// inside the tolerance the soak checks against, long enough (480 samples @ 48 kHz,
    /// ~100 Hz resolution) that the 1 kHz spacing between the four marker/base tones
    /// doesn't leak across bins.
    /// </summary>
    internal static List<double> DetectMarkerOnsets(
        float[] channel,
        int sampleRate,
        double frequency,
        double windowSeconds = 0.01,
        double hopSeconds = 0.002)
    {
        var windowSize = Math.Max(1, (int)(sampleRate * windowSeconds));
        var hopSize = Math.Max(1, (int)(sampleRate * hopSeconds));
        var onsets = new List<double>();
        if (channel.Length < windowSize) return onsets;

        // Hysteresis (two thresholds, not one) avoids double-counting a single burst if
        // its measured magnitude dips near the boundary mid-burst.
        const double onThreshold = 0.05;
        const double offThreshold = 0.02;

        var inBurst = false;
        for (int offset = 0; offset + windowSize <= channel.Length; offset += hopSize)
        {
            var magnitude = GoertzelMagnitude(
                channel.AsSpan(offset, windowSize), frequency, sampleRate);

            if (!inBurst && magnitude >= onThreshold)
            {
                onsets.Add(offset / (double)sampleRate);
                inBurst = true;
            }
            else if (inBurst && magnitude < offThreshold)
            {
                inBurst = false;
            }
        }
        return onsets;
    }

    /// <summary>
    /// Single-frequency Goertzel magnitude for a window, normalized by window length so
    /// it's comparable to a sine amplitude (a full-scale on-frequency tone of amplitude
    /// A yields magnitude ~= A/2).
    /// </summary>
    internal static double GoertzelMagnitude(ReadOnlySpan<float> window, double frequency, int sampleRate)
    {
        if (window.Length == 0) return 0;

        var binIndex = Math.Floor(0.5 + (window.Length * frequency / sampleRate));
        var omega = 2.0 * Math.PI * binIndex / window.Length;
        var coeff = 2.0 * Math.Cos(omega);

        double s1 = 0, s2 = 0;
        foreach (var sample in window)
        {
            var s0 = sample + (coeff * s1) - s2;
            s2 = s1;
            s1 = s0;
        }

        var real = s1 - (s2 * Math.Cos(omega));
        var imag = s2 * Math.Sin(omega);
        return Math.Sqrt((real * real) + (imag * imag)) / window.Length;
    }

    /// <summary>
    /// Current resident memory in bytes. Returns 0 (never garbage) if the query fails,
    /// which would only understate a leak rather than falsely flag one.
    /// </summary>
    internal static long CurrentResidentMemoryBytes()
    {
        try
        {
            using var process = Process.GetCurrentProcess();
            process.Refresh();
            return process.WorkingSet64;
        }
        catch (InvalidOperationException)
        {
            return 0;
        }
    }
}
