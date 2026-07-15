using System.Diagnostics;
using AudioCapture.Models;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace AudioCapture.Capture;

/// <summary>
/// An <see cref="IWaveIn"/> that replays an audio file instead of live hardware,
/// emitting <see cref="DataAvailable"/> buffers shaped like the real WASAPI sources.
///
/// This lets the whole capture pipeline — format conversion, mixing, sidecar
/// writing — run deterministically and headlessly, with no microphone, no
/// loopback device, and no audio endpoint at all. That last part is the point:
/// CI runners have no audio devices, so anything that touches
/// <c>MMDeviceEnumerator</c> fails there. Inject one of these into
/// <see cref="WasapiCaptureSession"/> as the mic and/or system factory.
///
/// The C# mirror of macOS <c>FilePlayerCaptureSource</c>; the two are expected to
/// behave the same, so change them together.
///
/// Emitted buffers match the shape of the source being stood in for:
/// <list type="bullet">
/// <item>Microphone — 16-bit mono PCM (see <see cref="Mono16"/>).</item>
/// <item>System loopback — 32-bit float stereo (see <see cref="StereoFloat"/>).</item>
/// </list>
///
/// <para><b>Restartability.</b> Each <see cref="StartRecording"/> rewinds to the
/// beginning of the file. A session may probe a source (start → sample → stop)
/// before real capture begins; a non-rewinding source would silently consume the
/// head of the fixture during that probe.</para>
///
/// <para><b>Pacing.</b> Buffers are delivered in real time on a drift-corrected
/// schedule by default, so downstream timing behaves as it would with live audio.
/// Raise <c>speedFactor</c> to replay long fixtures faster than real time in CI.</para>
/// </summary>
public sealed class FileWaveIn : IWaveIn
{
    private readonly string _filePath;
    private readonly TimeSpan _chunkDuration;
    private readonly double _speedFactor;
    private readonly bool _loop;
    private readonly object _lock = new();

    private WaveFormat _waveFormat;

    /// Fixture decoded into <see cref="_waveFormat"/>'s byte layout. Loaded lazily
    /// on first start and cached; invalidated when the format changes.
    private byte[]? _fixture;
    private int _readOffset;

    private CancellationTokenSource? _cts;
    private Task? _pumpTask;
    private bool _isRecording;
    private bool _disposed;

    public event EventHandler<WaveInEventArgs>? DataAvailable;
    public event EventHandler<StoppedEventArgs>? RecordingStopped;

    /// <summary>
    /// Total bytes handed to <see cref="DataAvailable"/> since construction.
    /// Survives restarts, so a test can assert the fixture actually flowed.
    /// </summary>
    public long BytesEmitted { get; private set; }

    /// <summary>Number of <see cref="DataAvailable"/> buffers raised since construction.</summary>
    public long ChunksEmitted { get; private set; }

    /// <summary>
    /// The format buffers are emitted in. Setting it re-converts the fixture on
    /// the next start — mirroring <c>WasapiCapture</c>, where the caller declares
    /// the format it wants to capture in. Cannot be changed mid-recording.
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
                if (_waveFormat.Equals(value)) return;
                _waveFormat = value;
                _fixture = null;
            }
        }
    }

    /// <param name="filePath">Audio fixture to replay. Converted to <paramref name="waveFormat"/> once.</param>
    /// <param name="waveFormat">Format to emit in. Drives channel count, sample rate, and encoding.</param>
    /// <param name="chunkDuration">Duration of each emitted buffer. Defaults to 10 ms, matching typical live-callback granularity.</param>
    /// <param name="speedFactor">Delivery speed relative to real time. 1.0 emits one second of audio per wall-clock second; higher is faster.</param>
    /// <param name="loop">When true, playback rewinds and continues instead of stopping at end-of-file.</param>
    public FileWaveIn(
        string filePath,
        WaveFormat waveFormat,
        TimeSpan? chunkDuration = null,
        double speedFactor = 1.0,
        bool loop = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        ArgumentNullException.ThrowIfNull(waveFormat);

        _filePath = filePath;
        _waveFormat = waveFormat;
        _chunkDuration = chunkDuration ?? TimeSpan.FromMilliseconds(10);
        _speedFactor = Math.Max(speedFactor, 0.0001);
        _loop = loop;

        if (_chunkDuration <= TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(chunkDuration), "Chunk duration must be positive");
    }

    /// <summary>
    /// A stand-in for the microphone: 16-bit mono PCM, the shape
    /// <see cref="WasapiCaptureSession"/> configures <c>WasapiCapture</c> to produce.
    /// </summary>
    public static FileWaveIn Mono16(
        string filePath,
        int sampleRate = 48000,
        TimeSpan? chunkDuration = null,
        double speedFactor = 1.0,
        bool loop = false) =>
        new(filePath, new WaveFormat(sampleRate, 16, 1), chunkDuration, speedFactor, loop);

    /// <summary>
    /// A stand-in for system loopback: 32-bit float stereo, the shape
    /// <c>WasapiLoopbackCapture</c> yields on a typical render device.
    /// </summary>
    public static FileWaveIn StereoFloat(
        string filePath,
        int sampleRate = 48000,
        TimeSpan? chunkDuration = null,
        double speedFactor = 1.0,
        bool loop = false) =>
        new(filePath, WaveFormat.CreateIeeeFloatWaveFormat(sampleRate, 2), chunkDuration, speedFactor, loop);

    /// <summary>Whether the backing fixture exists and can be opened.</summary>
    public bool IsAvailable => File.Exists(_filePath);

    /// <summary>
    /// Rewinds to the start of the fixture and begins delivering buffers until
    /// <see cref="StopRecording"/> (or end-of-file, when not looping). A second
    /// call while already recording is a no-op, matching NAudio's capture classes.
    /// </summary>
    public void StartRecording()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        byte[] fixture;
        WaveFormat format;
        lock (_lock)
        {
            if (_isRecording) return;
            format = _waveFormat;
        }

        // Load outside the lock — decoding can be slow and must not block a
        // concurrent StopRecording.
        fixture = LoadFixture(_filePath, format);

        CancellationTokenSource cts;
        lock (_lock)
        {
            if (_isRecording) return;
            _fixture = fixture;
            _readOffset = 0;
            _isRecording = true;
            cts = _cts = new CancellationTokenSource();
        }

        _pumpTask = Task.Run(() => PumpAsync(cts.Token));
    }

    /// <summary>
    /// Stops delivery and raises <see cref="RecordingStopped"/>. Safe to call when
    /// not recording.
    /// </summary>
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
        // The pump only ever awaits a cancellable delay, so this returns
        // promptly; the timeout is a backstop against a wedged handler.
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
        lock (_lock) _fixture = null;
    }

    // --- Private helpers ---

    /// <summary>
    /// Delivers chunks on a drift-corrected schedule: each chunk's deadline is
    /// computed from the start time rather than by accumulating sleeps, so a slow
    /// handler doesn't push the whole stream progressively late.
    /// </summary>
    private async Task PumpAsync(CancellationToken ct)
    {
        Exception? failure = null;
        try
        {
            var blockAlign = Math.Max(_waveFormat.BlockAlign, 1);
            var chunkFrames = Math.Max(1, (int)(_waveFormat.SampleRate * _chunkDuration.TotalSeconds));
            var chunkBytes = chunkFrames * blockAlign;
            var intervalMs = _chunkDuration.TotalMilliseconds / _speedFactor;

            var clock = Stopwatch.StartNew();
            long chunkIndex = 0;

            while (!ct.IsCancellationRequested)
            {
                var chunk = NextChunk(chunkBytes);
                if (chunk == null) break; // end of fixture, not looping

                DataAvailable?.Invoke(this, new WaveInEventArgs(chunk, chunk.Length));
                lock (_lock)
                {
                    BytesEmitted += chunk.Length;
                    ChunksEmitted++;
                }

                chunkIndex++;
                var deadlineMs = chunkIndex * intervalMs;
                var slackMs = deadlineMs - clock.Elapsed.TotalMilliseconds;
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

        // Reached end-of-fixture (or failed) without an explicit stop: report it
        // the way NAudio does, so callers see the same lifecycle as live capture.
        bool shouldReport;
        lock (_lock)
        {
            shouldReport = _isRecording;
            _isRecording = false;
        }
        if (shouldReport)
            RecordingStopped?.Invoke(this, new StoppedEventArgs(failure));
    }

    /// <summary>
    /// Copies the next <paramref name="chunkBytes"/> bytes out of the fixture,
    /// advancing the read position. Returns null at end-of-fixture when not looping.
    /// The final chunk may be short.
    /// </summary>
    private byte[]? NextChunk(int chunkBytes)
    {
        lock (_lock)
        {
            var fixture = _fixture;
            if (fixture == null || fixture.Length == 0) return null;

            if (_readOffset >= fixture.Length)
            {
                if (!_loop) return null;
                _readOffset = 0;
            }

            var count = Math.Min(chunkBytes, fixture.Length - _readOffset);
            if (count <= 0) return null;

            var chunk = new byte[count];
            Buffer.BlockCopy(fixture, _readOffset, chunk, 0, count);
            _readOffset += count;
            return chunk;
        }
    }

    /// <summary>
    /// Decodes the fixture and converts it to <paramref name="target"/>'s layout,
    /// returning the raw bytes a caller would have received from live capture.
    /// </summary>
    private static byte[] LoadFixture(string filePath, WaveFormat target)
    {
        if (!File.Exists(filePath))
            throw CaptureException.StorageError($"Cannot open audio fixture: {filePath} does not exist");

        float[] samples;
        try
        {
            using var reader = new AudioFileReader(filePath);
            ISampleProvider provider = reader;

            // Fold or duplicate channels before resampling — cheaper, and
            // StereoToMono's default 0.5/0.5 gains average the pair.
            var sourceChannels = provider.WaveFormat.Channels;
            if (sourceChannels != target.Channels)
            {
                provider = (sourceChannels, target.Channels) switch
                {
                    (2, 1) => new StereoToMonoSampleProvider(provider),
                    (1, 2) => new MonoToStereoSampleProvider(provider),
                    _ => throw CaptureException.StorageError(
                        $"Cannot convert audio fixture {Path.GetFileName(filePath)} from {sourceChannels} to {target.Channels} channels"),
                };
            }

            if (provider.WaveFormat.SampleRate != target.SampleRate)
                provider = new WdlResamplingSampleProvider(provider, target.SampleRate);

            samples = ReadAll(provider);
        }
        catch (CaptureException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw CaptureException.StorageError(
                $"Cannot open audio fixture {Path.GetFileName(filePath)}: {ex.Message}");
        }

        if (samples.Length == 0)
            throw CaptureException.StorageError($"Audio fixture {Path.GetFileName(filePath)} is empty");

        return Encode(samples, target);
    }

    private static float[] ReadAll(ISampleProvider provider)
    {
        var samples = new List<float>();
        // One second of audio per read.
        var buffer = new float[provider.WaveFormat.SampleRate * provider.WaveFormat.Channels];
        int read;
        while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
            samples.AddRange(buffer.AsSpan(0, read));
        return [.. samples];
    }

    /// <summary>Packs float samples into the target encoding's byte layout.</summary>
    private static byte[] Encode(float[] samples, WaveFormat target)
    {
        if (target.Encoding == WaveFormatEncoding.IeeeFloat && target.BitsPerSample == 32)
        {
            var bytes = new byte[samples.Length * 4];
            Buffer.BlockCopy(samples, 0, bytes, 0, bytes.Length);
            return bytes;
        }

        if (target.Encoding == WaveFormatEncoding.Pcm && target.BitsPerSample == 16)
        {
            var bytes = new byte[samples.Length * 2];
            for (int i = 0; i < samples.Length; i++)
            {
                var clamped = Math.Clamp(samples[i], -1f, 1f);
                var value = (short)(clamped * short.MaxValue);
                bytes[i * 2] = (byte)(value & 0xFF);
                bytes[i * 2 + 1] = (byte)((value >> 8) & 0xFF);
            }
            return bytes;
        }

        throw CaptureException.StorageError(
            $"Unsupported fixture output format: {target.Encoding} {target.BitsPerSample}-bit");
    }
}
