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
/// </summary>
public sealed class WasapiCaptureSession : ICaptureSession
{
    private readonly object _lock = new();
    private CaptureState _state = CaptureState.Idle;
    private CaptureConfiguration? _config;
    private AudioLevels _currentLevels = AudioLevels.Zero;

    // NAudio capture devices
    private WasapiCapture? _micCapture;
    private WasapiLoopbackCapture? _systemCapture;
    private MMDevice? _micDevice;

    // Writers
    private EncryptedWavWriter? _wavWriter;
    private FileStream? _micPcmWriter;
    private FileStream? _systemPcmWriter;

    // Mixer
    private readonly StereoMixer _mixer = new();

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

    public CaptureState State
    {
        get { lock (_lock) return _state; }
    }

    public AudioLevels CurrentLevels
    {
        get { lock (_lock) return _currentLevels; }
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

            // Resolve mic device
            if (configuration.EnableMicCapture)
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

        // Start mic capture
        if (config.EnableMicCapture && _micDevice != null)
        {
            _micCapture = new WasapiCapture(_micDevice);
            _micCapture.WaveFormat = new WaveFormat((int)config.SampleRate, config.BitDepth, 1);
            _micCapture.DataAvailable += OnMicDataAvailable;
            _micCapture.RecordingStopped += OnMicRecordingStopped;
            _micCapture.StartRecording();
        }

        // Start system loopback capture
        if (config.EnableSystemCapture)
        {
            _systemCapture = new WasapiLoopbackCapture();
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

    private void OnMicDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded == 0) return;

        lock (_lock)
        {
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
        }

        // Write raw PCM sidecar (encrypted if encryptor configured)
        WritePcmSidecar(_micPcmWriter, e.Buffer, e.BytesRecorded);
    }

    private void OnSystemDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded == 0) return;

        lock (_lock)
        {
            if (_state.Kind == CaptureStateKind.Paused) return;
        }

        // System loopback is typically 32-bit float stereo — convert as needed
        var format = _systemCapture!.WaveFormat;
        float[] samples;

        if (format.Encoding == WaveFormatEncoding.IeeeFloat && format.BitsPerSample == 32)
        {
            samples = new float[e.BytesRecorded / 4];
            Buffer.BlockCopy(e.Buffer, 0, samples, 0, e.BytesRecorded);
        }
        else
        {
            samples = ConvertToFloat(e.Buffer, e.BytesRecorded);
        }

        // For stereo system audio, compute RMS from mono-fold
        var frameCount = samples.Length / Math.Max(format.Channels, 1);
        float sum = 0;
        float peak = 0;
        for (int i = 0; i < frameCount; i++)
        {
            float val = 0;
            for (int ch = 0; ch < format.Channels; ch++)
            {
                var idx = i * format.Channels + ch;
                if (idx < samples.Length)
                    val += samples[idx];
            }
            val /= format.Channels;
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
        }

        if (_wavWriter == null || _config == null) return;

        try
        {
            var mixed = _mixer.Mix(mic, system, _config.MixingStrategy);
            var pcmData = StereoMixer.ConvertToInt16Pcm(mixed);
            _wavWriter.Write(pcmData);
        }
        catch (Exception ex)
        {
            var error = CaptureException.EncodingFailed($"Mix/write failed: {ex.Message}");
            Delegate?.OnError(error);
        }
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
