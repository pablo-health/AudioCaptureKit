using System.Diagnostics;
using AudioCapture.Interfaces;
using AudioCapture.Models;
using AudioCapture.Processing;
using AudioCapture.Storage;
using NAudio.CoreAudioApi;
using NAudio.Wave;

using CaptureState = AudioCapture.Models.CaptureState;

namespace AudioCapture.Capture;

/// <summary>
/// WASAPI-based capture session for Windows. Implements ICaptureSession.
/// Uses NAudio WasapiCapture (mic) + WasapiLoopbackCapture (system audio).
///
/// Either source can be replaced with an injected <see cref="IWaveIn"/> — see
/// <see cref="WasapiCaptureSession(Func{IWaveIn}, Func{IWaveIn})"/> — which lets
/// the pipeline run against file fixtures on machines with no audio hardware.
/// </summary>
public sealed class WasapiCaptureSession : ICaptureSession
{
    private readonly object _lock = new();

    // When set, these stand in for the WASAPI endpoints entirely.
    private readonly Func<IWaveIn>? _micFactory;
    private readonly Func<IWaveIn>? _systemFactory;

    private CaptureState _state = CaptureState.Idle;
    private CaptureConfiguration? _config;
    private AudioLevels _currentLevels = AudioLevels.Zero;

    // Capture sources. Typed as IWaveIn so injected sources drop straight in;
    // every use below is an IWaveIn member.
    private IWaveIn? _micCapture;
    private IWaveIn? _systemCapture;
    private MMDevice? _micDevice;

    // Diagnostics counters (protected by _lock).
    private long _mixCycles;
    private long _bytesWritten;
    private long _micChunks;
    private long _micBytes;
    private long _systemChunks;
    private long _systemBytes;
    private long _mixErrors;
    private int _peakBufferedSamples;

    // Writers
    private EncryptedWavWriter? _wavWriter;
    private FileStream? _micPcmWriter;
    private FileStream? _systemPcmWriter;

    // Mixer
    private readonly StereoMixer _mixer = new();

    // Reconciles the loopback endpoint's mix format to the configured shape.
    // Built once the source's format is known; owned by the capture callback.
    private SystemAudioNormalizer? _systemNormalizer;

    // Buffers for mixing (protected by _lock)
    private readonly List<float> _micBuffer = [];
    private readonly List<float> _systemBuffer = [];

    // Timing
    private readonly Stopwatch _durationStopwatch = new();
    private TaskCompletionSource<RecordingResult>? _stopTcs;
    private Timer? _maxDurationTimer;
    private Timer? _mixTimer;

    // File path for the main WAV recording (set in StartCaptureAsync)
    private string? _wavFilePath;

    // Level metering
    private float _micRms;
    private float _systemRms;
    private float _peakMic;
    private float _peakSystem;

    /// <summary>Captures from the real WASAPI mic and loopback endpoints.</summary>
    public WasapiCaptureSession()
    {
    }

    /// <summary>
    /// Captures from injected sources in place of the WASAPI endpoints.
    /// </summary>
    /// <remarks>
    /// An injected source fully replaces its endpoint: no <c>MMDeviceEnumerator</c>,
    /// no <c>WasapiCapture</c>, no <c>WasapiLoopbackCapture</c> is constructed for
    /// it — not in <see cref="Configure"/>, not in <see cref="StartCaptureAsync"/>.
    /// That total avoidance is the requirement, not an optimization: headless
    /// runners have no audio endpoints, and merely enumerating them there throws.
    ///
    /// Injected sources declare their own <see cref="IWaveIn.WaveFormat"/> — the
    /// session won't overwrite it — so the factory is responsible for producing
    /// the shape the pipeline expects: mono 16-bit PCM for the mic, stereo float
    /// for system audio. <see cref="FileWaveIn.Mono16"/> and
    /// <see cref="FileWaveIn.StereoFloat"/> build exactly those.
    /// </remarks>
    /// <param name="micFactory">Builds the mic source, or null to use the real WASAPI mic.</param>
    /// <param name="systemFactory">Builds the system-audio source, or null to use real loopback.</param>
    public WasapiCaptureSession(Func<IWaveIn>? micFactory, Func<IWaveIn>? systemFactory)
    {
        _micFactory = micFactory;
        _systemFactory = systemFactory;
    }

    public CaptureState State
    {
        get { lock (_lock) return _state; }
    }

    public AudioLevels CurrentLevels
    {
        get { lock (_lock) return _currentLevels; }
    }

    /// <summary>
    /// A snapshot of what has flowed through this session so far, readable during
    /// and after capture. Counters accumulate from construction — a session runs
    /// at most one capture, since no path leads back out of a terminal state.
    /// </summary>
    public CaptureDiagnostics Diagnostics
    {
        get
        {
            lock (_lock)
            {
                return new CaptureDiagnostics
                {
                    MixCycles = _mixCycles,
                    BytesWritten = _bytesWritten,
                    MicChunks = _micChunks,
                    MicBytes = _micBytes,
                    SystemChunks = _systemChunks,
                    SystemBytes = _systemBytes,
                    MixErrors = _mixErrors,
                    PeakBufferedSamples = _peakBufferedSamples,
                    SystemSourceSampleRate = _systemNormalizer?.SourceSampleRate ?? 0,
                    SystemSourceChannels = _systemNormalizer?.SourceChannels ?? 0,
                    SystemNormalized = _systemNormalizer is { IsPassthrough: false },
                };
            }
        }
    }

    public ICaptureDelegate? Delegate { get; set; }

    public void Configure(CaptureConfiguration configuration)
    {
        lock (_lock)
        {
            if (!_state.CanTransitionTo(CaptureStateKind.Configuring))
                throw CaptureException.ConfigurationFailed($"Cannot configure in state {_state.Kind}");

            TransitionTo(CaptureState.Configuring);
        }

        try
        {
            _config = configuration;
            Directory.CreateDirectory(configuration.OutputDirectory);

            // Resolve mic device. Skipped entirely when a mic source is injected:
            // MMDeviceEnumerator throws on machines with no audio endpoints, and
            // this runs before StartCaptureAsync — so guarding only the start path
            // would still fail here.
            if (configuration.EnableMicCapture && _micFactory == null)
            {
                using var enumerator = new MMDeviceEnumerator();
                _micDevice = configuration.MicDeviceId != null
                    ? enumerator.GetDevice(configuration.MicDeviceId)
                    : enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia);

                if (_micDevice == null)
                    throw CaptureException.DeviceNotAvailable("No microphone device found");
            }

            lock (_lock) TransitionTo(CaptureState.Ready);
        }
        catch (CaptureException)
        {
            lock (_lock) TransitionTo(CaptureState.Failed(CaptureException.ConfigurationFailed("Device configuration failed")));
            throw;
        }
        catch (Exception ex)
        {
            var error = CaptureException.ConfigurationFailed(ex.Message);
            lock (_lock) TransitionTo(CaptureState.Failed(error));
            throw error;
        }
    }

    public async Task<RecordingResult> StartCaptureAsync()
    {
        lock (_lock)
        {
            if (!_state.CanTransitionTo(CaptureStateKind.Capturing))
                throw CaptureException.ConfigurationFailed($"Cannot start capture in state {_state.Kind}");
        }

        var config = _config ?? throw CaptureException.ConfigurationFailed("Not configured");
        _stopTcs = new TaskCompletionSource<RecordingResult>();

        // Build file path
        var timestamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        var ext = config.Encryptor != null ? ".enc.wav" : ".wav";
        var filePath = Path.Combine(config.OutputDirectory, $"recording_{timestamp}{ext}");

        // Open WAV writer
        _wavFilePath = filePath;
        _wavWriter = new EncryptedWavWriter(filePath, config.Encryptor);
        _wavWriter.Open(config);

        // Open raw PCM sidecar files if requested
        // When encrypted, uses .enc.pcm extension with length-prefixed encrypted chunks
        // matching the macOS Swift implementation (no plaintext PCM on disk).
        string? micPcmPath = null;
        string? systemPcmPath = null;
        if (config.ExportRawPcm)
        {
            var pcmExt = config.Encryptor != null ? "enc.pcm" : "pcm";
            if (config.EnableMicCapture)
            {
                micPcmPath = Path.Combine(config.OutputDirectory, $"recording_{timestamp}_mic.{pcmExt}");
                _micPcmWriter = new FileStream(micPcmPath, FileMode.Create);
            }
            if (config.EnableSystemCapture)
            {
                systemPcmPath = Path.Combine(config.OutputDirectory, $"recording_{timestamp}_system.{pcmExt}");
                _systemPcmWriter = new FileStream(systemPcmPath, FileMode.Create);
            }
        }

        // Start mic capture. An injected factory stands in for the endpoint, so
        // there's no _micDevice to require in that case.
        if (config.EnableMicCapture && (_micFactory != null || _micDevice != null))
        {
            _micCapture = _micFactory?.Invoke() ?? CreateWasapiMic(config);
            _micCapture.DataAvailable += OnMicDataAvailable;
            _micCapture.RecordingStopped += OnMicRecordingStopped;
            _micCapture.StartRecording();
        }

        // Start system loopback capture
        if (config.EnableSystemCapture)
        {
            _systemCapture = _systemFactory?.Invoke() ?? new WasapiLoopbackCapture();

            // Built before the first callback can fire: the endpoint's format is
            // only knowable now, and OnSystemDataAvailable relies on this being set.
            _systemNormalizer = new SystemAudioNormalizer(
                _systemCapture.WaveFormat.SampleRate,
                _systemCapture.WaveFormat.Channels,
                (int)config.SampleRate);

            _systemCapture.DataAvailable += OnSystemDataAvailable;
            _systemCapture.RecordingStopped += OnSystemRecordingStopped;
            _systemCapture.StartRecording();
        }

        // Start periodic mix timer (every 100ms, mix buffered audio and write)
        _mixTimer = new Timer(MixAndWrite, null, TimeSpan.FromMilliseconds(100), TimeSpan.FromMilliseconds(100));

        // Start duration tracking
        _durationStopwatch.Restart();

        // Max duration timer
        if (config.MaxDuration.HasValue)
        {
            _maxDurationTimer = new Timer(
                _ => { _ = StopCaptureAsync(); },
                null,
                config.MaxDuration.Value,
                Timeout.InfiniteTimeSpan);
        }

        lock (_lock)
        {
            TransitionTo(CaptureState.Capturing(TimeSpan.Zero));
        }

        return await _stopTcs.Task;
    }

    public void PauseCapture()
    {
        lock (_lock)
        {
            if (!_state.CanTransitionTo(CaptureStateKind.Paused))
                return;

            _durationStopwatch.Stop();
            TransitionTo(CaptureState.Paused(_durationStopwatch.Elapsed));
        }
    }

    public void ResumeCapture()
    {
        lock (_lock)
        {
            if (!_state.CanTransitionTo(CaptureStateKind.Capturing))
                return;

            _durationStopwatch.Start();
            TransitionTo(CaptureState.Capturing(_durationStopwatch.Elapsed));
        }
    }

    public Task<RecordingResult> StopCaptureAsync()
    {
        lock (_lock)
        {
            if (_state.Kind != CaptureStateKind.Capturing && _state.Kind != CaptureStateKind.Paused)
                throw CaptureException.ConfigurationFailed($"Cannot stop in state {_state.Kind}");

            _durationStopwatch.Stop();
            TransitionTo(CaptureState.Stopping);
        }

        // Stop capture devices
        _mixTimer?.Dispose();
        _mixTimer = null;
        _maxDurationTimer?.Dispose();
        _maxDurationTimer = null;

        _micCapture?.StopRecording();
        _systemCapture?.StopRecording();

        // Flush remaining buffered audio
        MixAndWrite(null);

        // Close writers
        var checksum = _wavWriter?.Close() ?? "";
        _micPcmWriter?.Dispose();
        _micPcmWriter = null;
        _systemPcmWriter?.Dispose();
        _systemPcmWriter = null;

        var config = _config!;
        var duration = _durationStopwatch.Elapsed;
        var filePath = _wavFilePath ?? "";

        // Build tracks
        var tracks = new List<AudioTrack>();
        if (config.EnableMicCapture)
            tracks.Add(new AudioTrack(AudioTrackType.Mic, AudioChannel.Left, "Microphone"));
        if (config.EnableSystemCapture)
            tracks.Add(new AudioTrack(AudioTrackType.System, AudioChannel.Right, "System Audio"));

        var channelLayout = config.MixingStrategy == MixingStrategy.Separated
            ? ChannelLayout.SeparatedStereo
            : ChannelLayout.Blended;

        var rawPcmPaths = new List<string>();
        if (_config!.ExportRawPcm)
        {
            var pcmExt = config.Encryptor != null ? "enc.pcm" : "pcm";
            var timestamp = Path.GetFileNameWithoutExtension(filePath)
                .Replace("recording_", "").Replace(".enc", "");
            var micPcm = Path.Combine(config.OutputDirectory, $"recording_{timestamp}_mic.{pcmExt}");
            var sysPcm = Path.Combine(config.OutputDirectory, $"recording_{timestamp}_system.{pcmExt}");
            if (File.Exists(micPcm)) rawPcmPaths.Add(micPcm);
            if (File.Exists(sysPcm)) rawPcmPaths.Add(sysPcm);
        }

        var metadata = new RecordingMetadata(
            Id: Guid.NewGuid(),
            DurationSecs: duration.TotalSeconds,
            FilePath: filePath,
            Checksum: checksum,
            IsEncrypted: config.Encryptor != null,
            CreatedAt: DateTime.UtcNow,
            Tracks: [.. tracks],
            EncryptionAlgorithm: config.Encryptor?.Algorithm,
            EncryptionKeyId: config.Encryptor?.KeyMetadata.GetValueOrDefault("keyId"),
            ChannelLayout: channelLayout);

        var result = new RecordingResult(
            FilePath: filePath,
            DurationSecs: duration.TotalSeconds,
            Metadata: metadata,
            Checksum: checksum,
            RawPcmFilePaths: [.. rawPcmPaths]);

        // Clean up NAudio resources
        DisposeCapture();

        lock (_lock)
        {
            TransitionTo(CaptureState.Completed(result));
        }

        Delegate?.OnCaptureFinished(result);
        _stopTcs?.TrySetResult(result);

        return Task.FromResult(result);
    }

    public Task<AudioSource[]> GetAvailableAudioSourcesAsync() =>
        Task.FromResult(DeviceEnumerator.GetAllDevices());

    public void Dispose()
    {
        _mixTimer?.Dispose();
        _maxDurationTimer?.Dispose();
        DisposeCapture();
        _wavWriter?.Dispose();
        _micPcmWriter?.Dispose();
        _systemPcmWriter?.Dispose();
    }

    // --- Private helpers ---

    /// <summary>Builds the real WASAPI mic source in the configured capture format.</summary>
    private IWaveIn CreateWasapiMic(CaptureConfiguration config)
    {
        var capture = new WasapiCapture(_micDevice);
        capture.WaveFormat = new WaveFormat((int)config.SampleRate, config.BitDepth, 1);
        return capture;
    }

    private void OnMicDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded == 0) return;

        lock (_lock)
        {
            _micChunks++;
            _micBytes += e.BytesRecorded;
            if (_state.Kind == CaptureStateKind.Paused) return;
        }

        // Convert 16-bit PCM to float and buffer
        var samples = ConvertToFloat(e.Buffer, e.BytesRecorded);

        // Update mic level
        var rms = ComputeRms(samples);
        _micRms = rms;
        _peakMic = Math.Max(_peakMic, samples.Max(Math.Abs));
        UpdateLevels();

        lock (_lock)
        {
            _micBuffer.AddRange(samples);
            TrackPeakBuffered();
        }

        // Write raw PCM sidecar (encrypted if encryptor configured)
        WritePcmSidecar(_micPcmWriter, e.Buffer, e.BytesRecorded);
    }

    private void OnSystemDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded == 0) return;

        lock (_lock)
        {
            _systemChunks++;
            _systemBytes += e.BytesRecorded;
            if (_state.Kind == CaptureStateKind.Paused) return;
        }

        // System loopback is typically 32-bit float stereo — convert as needed
        var format = _systemCapture!.WaveFormat;
        float[] captured;

        if (format.Encoding == WaveFormatEncoding.IeeeFloat && format.BitsPerSample == 32)
        {
            captured = new float[e.BytesRecorded / 4];
            Buffer.BlockCopy(e.Buffer, 0, captured, 0, e.BytesRecorded);
        }
        else
        {
            captured = ConvertToFloat(e.Buffer, e.BytesRecorded);
        }

        // Reconcile the endpoint's mix format to the configured rate and stereo
        // layout before anything downstream sees it. Everything past this point —
        // levels, the mix buffer, the sidecar — assumes that shape, and the sidecar
        // is stamped with the configured rate regardless of what the device chose.
        var samples = _systemNormalizer!.Normalize(captured);
        const int channels = SystemAudioNormalizer.TargetChannels;

        // For stereo system audio, compute RMS from mono-fold
        var frameCount = samples.Length / channels;
        float sum = 0;
        float peak = 0;
        for (int i = 0; i < frameCount; i++)
        {
            float val = 0;
            for (int ch = 0; ch < channels; ch++)
            {
                var idx = i * channels + ch;
                if (idx < samples.Length)
                    val += samples[idx];
            }
            val /= channels;
            sum += val * val;
            peak = Math.Max(peak, Math.Abs(val));
        }
        _systemRms = frameCount > 0 ? MathF.Sqrt(sum / frameCount) : 0;
        _peakSystem = Math.Max(_peakSystem, peak);
        UpdateLevels();

        lock (_lock)
        {
            // If system audio is stereo, store as interleaved stereo
            _systemBuffer.AddRange(samples);
            TrackPeakBuffered();
        }

        // Write raw PCM sidecar as i16 LE (matching macOS format), encrypted if configured
        if (_systemPcmWriter != null)
        {
            var pcmBytes = ConvertFloatToInt16Pcm(samples);
            WritePcmSidecar(_systemPcmWriter, pcmBytes, pcmBytes.Length);
        }
    }

    private void MixAndWrite(object? state)
    {
        float[] mic;
        float[] system;

        lock (_lock)
        {
            if (_micBuffer.Count == 0 && _systemBuffer.Count == 0)
                return;

            mic = [.. _micBuffer];
            system = [.. _systemBuffer];
            _micBuffer.Clear();
            _systemBuffer.Clear();
            _mixCycles++;
        }

        if (_wavWriter == null || _config == null) return;

        try
        {
            var mixed = _mixer.Mix(mic, system, _config.MixingStrategy);
            var pcmData = StereoMixer.ConvertToInt16Pcm(mixed);
            _wavWriter.Write(pcmData);
            lock (_lock) _bytesWritten += pcmData.Length;
        }
        catch (Exception ex)
        {
            lock (_lock) _mixErrors++;
            var error = CaptureException.EncodingFailed($"Mix/write failed: {ex.Message}");
            Delegate?.OnError(error);
        }
    }

    /// <summary>
    /// Records the high-water mark of samples awaiting a mix cycle. Must be called
    /// with <see cref="_lock"/> held.
    /// </summary>
    private void TrackPeakBuffered()
    {
        var buffered = _micBuffer.Count + _systemBuffer.Count;
        if (buffered > _peakBufferedSamples)
            _peakBufferedSamples = buffered;
    }

    private void UpdateLevels()
    {
        var levels = new AudioLevels(_micRms, _systemRms, _peakMic, _peakSystem);
        lock (_lock) _currentLevels = levels;
        Delegate?.OnLevelsUpdated(levels);
    }

    private void TransitionTo(CaptureState newState)
    {
        _state = newState;
        Delegate?.OnStateChanged(newState);
    }

    private void OnMicRecordingStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception != null)
            Delegate?.OnError(CaptureException.DeviceNotAvailable($"Mic stopped: {e.Exception.Message}"));
    }

    private void OnSystemRecordingStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception != null)
            Delegate?.OnError(CaptureException.DeviceNotAvailable($"System audio stopped: {e.Exception.Message}"));
    }

    private void DisposeCapture()
    {
        if (_micCapture != null)
        {
            _micCapture.DataAvailable -= OnMicDataAvailable;
            _micCapture.RecordingStopped -= OnMicRecordingStopped;
            _micCapture.Dispose();
            _micCapture = null;
        }
        if (_systemCapture != null)
        {
            _systemCapture.DataAvailable -= OnSystemDataAvailable;
            _systemCapture.RecordingStopped -= OnSystemRecordingStopped;
            _systemCapture.Dispose();
            _systemCapture = null;
        }
        _micDevice = null;
    }

    private static float[] ConvertToFloat(byte[] buffer, int bytesRecorded)
    {
        var sampleCount = bytesRecorded / 2;
        var samples = new float[sampleCount];
        for (int i = 0; i < sampleCount; i++)
        {
            short sample = (short)(buffer[i * 2] | (buffer[i * 2 + 1] << 8));
            samples[i] = sample / (float)short.MaxValue;
        }
        return samples;
    }

    private static float ComputeRms(float[] samples)
    {
        if (samples.Length == 0) return 0;
        float sum = 0;
        foreach (var s in samples)
            sum += s * s;
        return MathF.Sqrt(sum / samples.Length);
    }

    /// <summary>
    /// Writes a PCM chunk to a sidecar file. When an encryptor is configured,
    /// writes encrypted chunks in the same length-prefixed format as the main WAV:
    /// [4-byte LE length][nonce|ciphertext|tag]. This matches the macOS Swift implementation.
    /// </summary>
    private void WritePcmSidecar(FileStream? writer, byte[] data, int count)
    {
        if (writer == null) return;

        if (_config?.Encryptor != null)
        {
            var chunk = new byte[count];
            Buffer.BlockCopy(data, 0, chunk, 0, count);
            var encrypted = _config.Encryptor.Encrypt(chunk);
            var lengthBytes = BitConverter.GetBytes((uint)encrypted.Length);
            if (!BitConverter.IsLittleEndian)
                Array.Reverse(lengthBytes);
            writer.Write(lengthBytes, 0, 4);
            writer.Write(encrypted, 0, encrypted.Length);
        }
        else
        {
            writer.Write(data, 0, count);
        }
    }

    /// <summary>
    /// Converts float32 samples to signed 16-bit LE PCM bytes.
    /// Used to write system audio sidecars in the same i16 format as mic sidecars,
    /// matching the macOS implementation (convertToInt16PCM).
    /// </summary>
    private static byte[] ConvertFloatToInt16Pcm(float[] samples)
    {
        var bytes = new byte[samples.Length * 2];
        for (int i = 0; i < samples.Length; i++)
        {
            var clamped = Math.Clamp(samples[i], -1.0f, 1.0f);
            short value = (short)(clamped * short.MaxValue);
            bytes[i * 2] = (byte)(value & 0xFF);
            bytes[i * 2 + 1] = (byte)((value >> 8) & 0xFF);
        }
        return bytes;
    }
}
