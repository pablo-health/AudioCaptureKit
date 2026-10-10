using System.Diagnostics;
using NAudio.Wave;

namespace AudioCapture.Tests;

/// <summary>
/// A real-time paced sine source with a script: windows where it delivers nothing at
/// all (what WASAPI loopback does while nothing renders), and an optional point where
/// it dies with an exception (what an invalidated endpoint does). Stands in for the
/// loopback endpoint in tests that need those two behaviours, which neither
/// <c>FileWaveIn</c> nor <c>SignalGeneratorWaveIn</c> models.
/// </summary>
internal sealed class ScriptedWaveIn : IWaveIn
{
    private readonly double _frequency;
    private readonly Func<double, bool> _isSilent;
    private readonly TimeSpan? _failAfter;
    private readonly TimeSpan _chunk = TimeSpan.FromMilliseconds(10);
    private CancellationTokenSource? _cts;
    private Task? _pump;
    private long _phaseFrames;

    public event EventHandler<WaveInEventArgs>? DataAvailable;
    public event EventHandler<StoppedEventArgs>? RecordingStopped;

    public WaveFormat WaveFormat { get; set; }

    /// <summary>True between StartRecording and the source stopping (either way).</summary>
    public bool IsRecording { get; private set; }

    /// <summary>Frames actually delivered (silent windows excluded).</summary>
    public long FramesDelivered { get; private set; }

    /// <param name="sampleRate">Delivered rate.</param>
    /// <param name="frequency">Tone frequency in Hz.</param>
    /// <param name="isSilent">Given seconds since start, whether to deliver nothing.</param>
    /// <param name="failAfter">When set, stop with an exception after this long.</param>
    /// <param name="stereoFloat">Stereo IEEE float (loopback shape) or mono 16-bit PCM (mic shape).</param>
    public ScriptedWaveIn(
        int sampleRate,
        double frequency = 1000,
        Func<double, bool>? isSilent = null,
        TimeSpan? failAfter = null,
        bool stereoFloat = true)
    {
        _frequency = frequency;
        _isSilent = isSilent ?? (_ => false);
        _failAfter = failAfter;
        WaveFormat = stereoFloat
            ? WaveFormat.CreateIeeeFloatWaveFormat(sampleRate, 2)
            : new WaveFormat(sampleRate, 16, 1);
    }

    public void StartRecording()
    {
        IsRecording = true;
        _cts = new CancellationTokenSource();
        var token = _cts.Token;
        _pump = Task.Run(() => PumpAsync(token));
    }

    public void StopRecording()
    {
        if (!IsRecording) return;
        IsRecording = false;
        _cts?.Cancel();
        try { _pump?.Wait(TimeSpan.FromSeconds(5)); }
        catch (AggregateException) { /* cancelled */ }
        RecordingStopped?.Invoke(this, new StoppedEventArgs());
    }

    public void Dispose()
    {
        StopRecording();
        _cts?.Dispose();
    }

    private async Task PumpAsync(CancellationToken ct)
    {
        var rate = WaveFormat.SampleRate;
        var chunkFrames = (int)(rate * _chunk.TotalSeconds);
        var clock = Stopwatch.StartNew();
        long index = 0;
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var t = index * _chunk.TotalSeconds;
                if (_failAfter is { } fail && clock.Elapsed >= fail)
                {
                    IsRecording = false;
                    RecordingStopped?.Invoke(this, new StoppedEventArgs(new InvalidOperationException("endpoint invalidated")));
                    return;
                }

                if (!_isSilent(t))
                {
                    var chunk = Render(chunkFrames, rate);
                    DataAvailable?.Invoke(this, new WaveInEventArgs(chunk, chunk.Length));
                    FramesDelivered += chunkFrames;
                }
                else
                {
                    _phaseFrames += chunkFrames;
                }

                index++;
                var slack = (index * _chunk.TotalMilliseconds) - clock.Elapsed.TotalMilliseconds;
                if (slack > 0)
                    await Task.Delay(TimeSpan.FromMilliseconds(slack), ct).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            // StopRecording reports.
        }
    }

    private byte[] Render(int frames, int rate)
    {
        var stereo = WaveFormat.Channels == 2;
        var bytes = new byte[frames * WaveFormat.BlockAlign];
        for (int i = 0; i < frames; i++)
        {
            var value = (float)(0.5 * Math.Sin(2 * Math.PI * _frequency * (_phaseFrames + i) / rate));
            if (stereo)
            {
                BitConverter.TryWriteBytes(bytes.AsSpan(i * 8), value);
                BitConverter.TryWriteBytes(bytes.AsSpan((i * 8) + 4), value);
            }
            else
            {
                BitConverter.TryWriteBytes(bytes.AsSpan(i * 2), (short)(value * short.MaxValue));
            }
        }
        _phaseFrames += frames;
        return bytes;
    }
}
