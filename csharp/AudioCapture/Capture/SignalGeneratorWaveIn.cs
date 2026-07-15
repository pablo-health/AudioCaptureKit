using System.Diagnostics;
using AudioCapture.Models;
using NAudio.Wave;

namespace AudioCapture.Capture;

/// <summary>
/// An <see cref="IWaveIn"/> that synthesizes a deterministic tone bed with periodic
/// marker bursts, instead of replaying a fixture file.
///
/// <para>Unlike <see cref="FileWaveIn"/> (which loops a short recorded clip), this
/// source generates every sample analytically from its frame index — no file I/O, no
/// RNG, no loop seam. That determinism is what makes it useful for the capture soak:
/// every marker's frequency and position is known in advance, so a test can read the
/// finalized recording back and prove the pipeline preserved both channel separation
/// (no mic/system bleed) and timing (no drift or loss across a long real-time run).</para>
///
/// <para>The signal is a continuous <see cref="MarkerTone.BaseFrequency"/> tone with a
/// <see cref="MarkerTone.MarkerFrequency"/> burst added on top once every
/// <see cref="MarkerTone.MarkerPeriod"/> seconds, starting at
/// <see cref="MarkerTone.MarkerOffset"/>. Giving the mic and system sources different
/// base/marker pairs (and an offset between their schedules) means a marker detected on
/// the wrong channel, or at the wrong time, unambiguously points at a capture-pipeline
/// bug rather than a coincidence in the fixture.</para>
///
/// <para><b>Restartability.</b> Like <see cref="FileWaveIn"/>, each
/// <see cref="StartRecording"/> resets the frame clock to zero, so a probe/start cycle
/// doesn't skew the marker schedule.</para>
///
/// The C# mirror of Swift <c>SignalGeneratorCaptureSource</c>; the two are expected to
/// behave the same, so change them together.
/// </summary>
public sealed class SignalGeneratorWaveIn : IWaveIn
{
    /// <summary>Describes a continuous tone bed with a periodic marker burst added on top.</summary>
    /// <param name="BaseFrequency">Frequency of the continuous tone bed, in Hz.</param>
    /// <param name="MarkerFrequency">Frequency of the periodic marker burst, in Hz.</param>
    /// <param name="MarkerPeriod">Seconds between the start of one marker burst and the next.</param>
    /// <param name="MarkerOffset">Seconds after source-time zero before the first burst starts.</param>
    /// <param name="MarkerDuration">Duration of each marker burst, in seconds.</param>
    public readonly record struct MarkerTone(
        double BaseFrequency,
        double MarkerFrequency,
        double MarkerPeriod,
        double MarkerOffset = 0,
        double MarkerDuration = 1.0)
    {
        /// <summary>Whether a marker burst is sounding at <paramref name="sourceTime"/> (seconds since start).</summary>
        public bool IsMarkerActive(double sourceTime)
        {
            if (sourceTime < MarkerOffset) return false;
            var sincePhaseStart = (sourceTime - MarkerOffset) % MarkerPeriod;
            return sincePhaseStart < MarkerDuration;
        }
    }

    private readonly MarkerTone _tone;
    private readonly float _baseAmplitude;
    private readonly float _markerAmplitude;
    private readonly TimeSpan _chunkDuration;
    private readonly object _lock = new();

    private WaveFormat _waveFormat;
    private long _emittedFrames;
    private CancellationTokenSource? _cts;
    private Task? _pumpTask;
    private bool _isRecording;
    private bool _disposed;

    public event EventHandler<WaveInEventArgs>? DataAvailable;
    public event EventHandler<StoppedEventArgs>? RecordingStopped;

    /// <summary>
    /// The format buffers are synthesized in. Setting it drives channel count and sample
    /// rate — and therefore the marker schedule's frame math — so, as with
    /// <see cref="FileWaveIn"/>, it cannot change mid-recording.
    /// </summary>
    public WaveFormat WaveFormat
    {
        get { lock (_lock) return _waveFormat; }
        set
        {
            ArgumentNullException.ThrowIfNull(value);
            lock (_lock)
            {
                if (_isRecording)
                    throw new InvalidOperationException("Cannot change WaveFormat while recording");
                _waveFormat = value;
            }
        }
    }

    /// <param name="waveFormat">Format to emit in. Every channel carries the same tone bed.</param>
    /// <param name="tone">The base/marker frequency pair and marker schedule.</param>
    /// <param name="baseAmplitude">Amplitude of the continuous tone, in [-1, 1].</param>
    /// <param name="markerAmplitude">
    /// Amplitude added during a marker burst. Summed with <paramref name="baseAmplitude"/> this
    /// stays under full scale, avoiding clipping that would smear the marker's frequency content
    /// with harmonics and confuse the detector.
    /// </param>
    /// <param name="chunkDuration">Duration of each emitted buffer. Defaults to 10 ms, matching typical live-callback granularity.</param>
    public SignalGeneratorWaveIn(
        WaveFormat waveFormat,
        MarkerTone tone,
        float baseAmplitude = 0.4f,
        float markerAmplitude = 0.3f,
        TimeSpan? chunkDuration = null)
    {
        ArgumentNullException.ThrowIfNull(waveFormat);

        _waveFormat = waveFormat;
        _tone = tone;
        _baseAmplitude = baseAmplitude;
        _markerAmplitude = markerAmplitude;
        _chunkDuration = chunkDuration ?? TimeSpan.FromMilliseconds(10);

        if (_chunkDuration <= TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(chunkDuration), "Chunk duration must be positive");
    }

    /// <summary>A stand-in for the microphone: 16-bit mono PCM.</summary>
    public static SignalGeneratorWaveIn Mono16(MarkerTone tone, int sampleRate = 48000) =>
        new(new WaveFormat(sampleRate, 16, 1), tone);

    /// <summary>A stand-in for system loopback: 32-bit float stereo.</summary>
    public static SignalGeneratorWaveIn StereoFloat(MarkerTone tone, int sampleRate = 48000) =>
        new(WaveFormat.CreateIeeeFloatWaveFormat(sampleRate, 2), tone);

    /// <summary>Always available — there's no hardware or file dependency to fail.</summary>
    public bool IsAvailable => true;

    /// <summary>
    /// Resets the frame clock to zero and begins delivering buffers until
    /// <see cref="StopRecording"/>. A second call while already recording is a no-op,
    /// matching NAudio's capture classes.
    /// </summary>
    public void StartRecording()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        CancellationTokenSource cts;
        lock (_lock)
        {
            if (_isRecording) return;
            _emittedFrames = 0;
            _isRecording = true;
            cts = _cts = new CancellationTokenSource();
        }

        _pumpTask = Task.Run(() => PumpAsync(cts.Token));
    }

    /// <summary>Stops generating and raises <see cref="RecordingStopped"/>. Safe to call when not recording.</summary>
    public void StopRecording()
    {
        CancellationTokenSource? cts;
        Task? pump;
        lock (_lock)
        {
            if (!_isRecording) return;
            _isRecording = false;
            cts = _cts;
            _cts = null;
            pump = _pumpTask;
            _pumpTask = null;
        }

        cts?.Cancel();
        // The pump only ever awaits a cancellable delay, so this returns promptly;
        // the timeout is a backstop against a wedged handler.
        try { pump?.Wait(TimeSpan.FromSeconds(5)); }
        catch (AggregateException) { /* surfaced via RecordingStopped */ }
        cts?.Dispose();

        RecordingStopped?.Invoke(this, new StoppedEventArgs());
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try { StopRecording(); }
        catch (ObjectDisposedException) { /* already torn down */ }
    }

    // --- Private helpers ---

    /// <summary>
    /// Delivers chunks on a drift-corrected schedule: each chunk's deadline is computed
    /// from the start time rather than by accumulating sleeps, so a slow handler doesn't
    /// push the whole stream progressively late — which would show up as marker drift and
    /// be indistinguishable from the pipeline bug this source exists to detect.
    /// </summary>
    private async Task PumpAsync(CancellationToken ct)
    {
        Exception? failure = null;
        try
        {
            var chunkFrames = Math.Max(1, (int)(WaveFormat.SampleRate * _chunkDuration.TotalSeconds));
            var intervalMs = _chunkDuration.TotalMilliseconds;

            var clock = Stopwatch.StartNew();
            long chunkIndex = 0;

            while (!ct.IsCancellationRequested)
            {
                var chunk = NextChunk(chunkFrames);
                DataAvailable?.Invoke(this, new WaveInEventArgs(chunk, chunk.Length));

                chunkIndex++;
                var slackMs = (chunkIndex * intervalMs) - clock.Elapsed.TotalMilliseconds;
                if (slackMs > 0)
                    await Task.Delay(TimeSpan.FromMilliseconds(slackMs), ct).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            return; // StopRecording raises RecordingStopped itself
        }
        catch (Exception ex)
        {
            failure = ex;
        }

        bool shouldReport;
        lock (_lock)
        {
            shouldReport = _isRecording;
            _isRecording = false;
        }
        if (shouldReport)
            RecordingStopped?.Invoke(this, new StoppedEventArgs(failure));
    }

    /// <summary>Synthesizes the next chunk and advances the frame clock.</summary>
    private byte[] NextChunk(int chunkFrames)
    {
        long startFrame;
        lock (_lock)
        {
            startFrame = _emittedFrames;
            _emittedFrames += chunkFrames;
        }

        var channels = WaveFormat.Channels;
        var samples = new float[chunkFrames * channels];
        for (int i = 0; i < chunkFrames; i++)
        {
            var value = Sample(startFrame + i);
            for (int ch = 0; ch < channels; ch++)
                samples[(i * channels) + ch] = value;
        }
        return Encode(samples);
    }

    /// <summary>The synthesized sample at a given frame index — deterministic, no RNG.</summary>
    private float Sample(long frame)
    {
        var sourceTime = frame / (double)WaveFormat.SampleRate;
        var value = (float)Math.Sin(2.0 * Math.PI * _tone.BaseFrequency * sourceTime) * _baseAmplitude;
        if (_tone.IsMarkerActive(sourceTime))
            value += (float)Math.Sin(2.0 * Math.PI * _tone.MarkerFrequency * sourceTime) * _markerAmplitude;
        return value;
    }

    /// <summary>Packs float samples into the emitted format's byte layout.</summary>
    private byte[] Encode(float[] samples)
    {
        if (WaveFormat.Encoding == WaveFormatEncoding.IeeeFloat && WaveFormat.BitsPerSample == 32)
        {
            var bytes = new byte[samples.Length * 4];
            Buffer.BlockCopy(samples, 0, bytes, 0, bytes.Length);
            return bytes;
        }

        if (WaveFormat.Encoding == WaveFormatEncoding.Pcm && WaveFormat.BitsPerSample == 16)
        {
            var bytes = new byte[samples.Length * 2];
            for (int i = 0; i < samples.Length; i++)
            {
                var clamped = Math.Clamp(samples[i], -1f, 1f);
                var value = (short)(clamped * short.MaxValue);
                bytes[i * 2] = (byte)(value & 0xFF);
                bytes[(i * 2) + 1] = (byte)((value >> 8) & 0xFF);
            }
            return bytes;
        }

        throw CaptureException.StorageError(
            $"Unsupported signal-generator output format: {WaveFormat.Encoding} {WaveFormat.BitsPerSample}-bit");
    }
}
