using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace AudioCapture.Processing;

/// <summary>
/// Reconciles live system-loopback audio to the shape the rest of the capture
/// graph assumes: interleaved stereo at the configured sample rate.
///
/// <para>Unlike the mic, a loopback endpoint's format is not ours to choose —
/// <c>WasapiLoopbackCapture</c> runs at whatever mix format the render device
/// declares. Two consequences, both silent:</para>
///
/// <list type="bullet">
/// <item><b>Rate.</b> A 44.1 kHz endpoint delivers 44 100 frames per second into
/// a pipeline whose sidecar is later stamped with the <i>configured</i> rate
/// (48 kHz). Nothing errors; the audio simply plays ~9% fast, which is enough to
/// degrade transcription.</item>
/// <item><b>Channels.</b> <see cref="StereoMixer"/> documents its system input as
/// interleaved stereo. A mono or 5.1 endpoint hands it frames in another layout,
/// which it reads as stereo — garbling the result.</item>
/// </list>
///
/// <para>So this sits directly on the endpoint's output and makes those
/// assumptions true. When the endpoint already matches the target, it is a
/// pass-through and allocates no resampler.</para>
///
/// <para><b>Threading.</b> Not thread-safe, by design: it carries the resampler's
/// filter state across chunks and is only ever driven from the single capture
/// callback that owns the source.</para>
/// </summary>
public sealed class SystemAudioNormalizer
{
    /// <summary>The channel count every consumer downstream expects.</summary>
    public const int TargetChannels = 2;

    private readonly PushSampleProvider? _pushed;
    private readonly ISampleProvider? _resampler;

    public int SourceSampleRate { get; }
    public int SourceChannels { get; }
    public int TargetSampleRate { get; }

    /// <summary>True when the endpoint already matches the target and samples pass through untouched.</summary>
    public bool IsPassthrough => _resampler is null && SourceChannels == TargetChannels;

    /// <param name="sourceSampleRate">The endpoint's mix-format rate.</param>
    /// <param name="sourceChannels">The endpoint's mix-format channel count.</param>
    /// <param name="targetSampleRate">The configured capture rate the sidecar will be stamped with.</param>
    public SystemAudioNormalizer(int sourceSampleRate, int sourceChannels, int targetSampleRate)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(sourceSampleRate);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(sourceChannels);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(targetSampleRate);

        SourceSampleRate = sourceSampleRate;
        TargetSampleRate = targetSampleRate;
        SourceChannels = sourceChannels;

        if (sourceSampleRate != targetSampleRate)
        {
            // Channels are folded before the resampler runs, so it only ever sees
            // stereo — fewer samples to filter, and one less shape to reason about.
            _pushed = new PushSampleProvider(
                WaveFormat.CreateIeeeFloatWaveFormat(sourceSampleRate, TargetChannels));
            _resampler = new WdlResamplingSampleProvider(_pushed, targetSampleRate);
        }
    }

    /// <summary>
    /// Converts one capture buffer to interleaved stereo at the target rate.
    /// </summary>
    /// <param name="interleaved">Float samples in the endpoint's own layout.</param>
    /// <remarks>
    /// Output length tracks input only on average, not per call: a resampler holds
    /// filter state, so it may return slightly more or fewer frames than the ratio
    /// implies for any single buffer. Callers must treat the result as a stream, not
    /// a per-chunk mapping.
    /// </remarks>
    public float[] Normalize(float[] interleaved)
    {
        ArgumentNullException.ThrowIfNull(interleaved);
        if (interleaved.Length == 0) return [];

        var stereo = FoldToStereo(interleaved);
        if (_resampler is null) return stereo;

        _pushed!.Push(stereo);
        return Drain(stereo.Length);
    }

    // --- Private helpers ---

    /// <summary>
    /// Maps the endpoint's channel layout onto stereo.
    /// </summary>
    private float[] FoldToStereo(float[] interleaved)
    {
        if (SourceChannels == TargetChannels) return interleaved;

        var frames = interleaved.Length / SourceChannels;
        var stereo = new float[frames * TargetChannels];

        if (SourceChannels == 1)
        {
            for (int i = 0; i < frames; i++)
                stereo[i * 2] = stereo[i * 2 + 1] = interleaved[i];
            return stereo;
        }

        // More than two channels: average them all into both legs rather than
        // taking the first pair. Speech on a centre or surround channel is what
        // this sidecar exists to carry, so losing spatial placement is the right
        // trade against dropping the dialogue entirely.
        for (int i = 0; i < frames; i++)
        {
            float sum = 0;
            for (int ch = 0; ch < SourceChannels; ch++)
                sum += interleaved[i * SourceChannels + ch];

            var mono = sum / SourceChannels;
            stereo[i * 2] = stereo[i * 2 + 1] = mono;
        }
        return stereo;
    }

    /// <summary>
    /// Pulls everything the resampler can currently produce.
    /// </summary>
    private float[] Drain(int pushedSamples)
    {
        // Enough for the rate-converted chunk plus the resampler's carried frames,
        // so the common case drains in a single read.
        var estimate = (int)(pushedSamples * ((double)TargetSampleRate / SourceSampleRate));
        var buffer = new float[Math.Max(estimate + (TargetChannels * 64), 1024)];

        var read = _resampler!.Read(buffer, 0, buffer.Length);
        if (read < buffer.Length)
            return buffer.AsSpan(0, read).ToArray();

        // Filled the buffer — there may be more waiting.
        var output = new List<float>(buffer);
        while ((read = _resampler.Read(buffer, 0, buffer.Length)) > 0)
        {
            output.AddRange(buffer.AsSpan(0, read));
            if (read < buffer.Length) break;
        }
        return [.. output];
    }

    /// <summary>
    /// An <see cref="ISampleProvider"/> fed by pushed buffers instead of pulling
    /// from a source. Returns short (or empty) reads when drained rather than
    /// padding with silence — padding would splice fake frames into the timeline
    /// every time a chunk boundary fell mid-read.
    /// </summary>
    private sealed class PushSampleProvider(WaveFormat waveFormat) : ISampleProvider
    {
        private readonly Queue<float> _queue = new();

        public WaveFormat WaveFormat { get; } = waveFormat;

        public void Push(float[] samples)
        {
            foreach (var sample in samples)
                _queue.Enqueue(sample);
        }

        public int Read(float[] buffer, int offset, int count)
        {
            int written = 0;
            while (written < count && _queue.Count > 0)
                buffer[offset + written++] = _queue.Dequeue();
            return written;
        }
    }
}
