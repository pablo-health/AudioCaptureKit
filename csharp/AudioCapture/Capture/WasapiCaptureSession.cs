using System.Diagnostics;
using AudioCapture.Interfaces;
using AudioCapture.Models;
using AudioCapture.Processing;
using AudioCapture.Storage;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
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
///
/// <para><b>System channel on the clock.</b> WASAPI loopback delivers nothing while
/// nothing renders, and nothing while it is between devices. Left alone, the system
/// sidecar would simply be shorter than the mic by every silent stretch and drift out
/// of alignment with it. So the mix pump pads the system channel with silence, in the
/// sample domain, whenever loopback has been quiet for longer than
/// <see cref="SystemGapThreshold"/> — up to the mic's frame count (the mic is the
/// primary clock, as on macOS), or the session stopwatch when there is no mic.</para>
///
/// <para><b>Device following.</b> With
/// <see cref="CaptureConfiguration.FollowDefaultOutputDevice"/> set, the session
/// listens for endpoint changes and re-opens loopback in place on the new
/// <c>Console</c> default render device; writers and sidecars stay open and the
/// switch gap is padded like any other silence.</para>
/// </summary>
public sealed class WasapiCaptureSession : ICaptureSession
{
    /// <summary>
    /// How long loopback may stay silent before the system channel is padded. Normal
    /// WASAPI packets arrive every ~10 ms; this matches the mixer's half-second stall
    /// guard, so ordinary scheduling jitter (or a loaded test runner) never pads, and
    /// anything padded too early is trimmed back when the late audio arrives (see
    /// <see cref="TrimOvershoot"/>).
    /// </summary>
    internal static readonly TimeSpan SystemGapThreshold = TimeSpan.FromMilliseconds(500);

    // How far the system channel may run ahead of its reference before late frames are
    // traded against previously padded silence: two mic callbacks' worth of jitter.
    private static readonly TimeSpan SystemOvershootTolerance = TimeSpan.FromMilliseconds(20);

    // Consecutive loopback errors retried (with following on) before giving up.
    private const int MaxSystemRetries = 3;

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
    private string? _micDeviceId;

    // Real-endpoint plumbing: one enumerator for the session's lifetime, which also
    // carries the endpoint-change subscription. Never created for injected sources.
    private MMDeviceEnumerator? _enumerator;
    private EndpointWatcher? _endpointWatcher;

    // Diagnostics counters (protected by _lock).
    private long _mixCycles;
    private long _bytesWritten;
    private long _micChunks;
    private long _micBytes;
    private long _systemChunks;
    private long _systemBytes;
    private long _mixErrors;
    private int _peakBufferedSamples;
    private WaveFormat? _micFormat;
    private long _micFramesCaptured;
    private long _systemPaddedFrames;
    private long _systemTrimmedFrames;
    private int _systemSourceSwitches;
    private int _systemSourceErrors;
    private string? _systemDeviceId;

    // --- System path (protected by _systemLock) ---
    //
    // Everything that turns a loopback buffer into system-channel frames: which source
    // is current, its format, and the running frame accounting that keeps the channel
    // on the clock. One lock, so a real buffer, a padding run and a device swap can
    // never interleave mid-chunk. Lock order: _systemLock, then _lock — never the
    // reverse.
    private readonly object _systemLock = new();
    private WaveFormat? _systemFormat;
    private long _systemEmittedFrames;
    private long _systemPadCredit;
    private long _systemLastDataTimestamp;
    private int _systemRetryAttempts;

    // Serializes device re-opens; each one chains after the last.
    private readonly object _reopenLock = new();
    private Task _reopenChain = Task.CompletedTask;

    // Writers
    private EncryptedWavWriter? _wavWriter;

    // Sidecars. SidecarStreamWriter serializes write against close internally: NAudio's
    // StopRecording only signals its capture thread, so a DataAvailable handler can
    // still be writing as stop closes the file, and FileStream is not safe for
    // concurrent write/dispose. A write after close is dropped instead — an
    // undecryptable sidecar is not worth leaving to timing.
    private SidecarStreamWriter? _micSidecar;
    private SidecarStreamWriter? _systemSidecar;

    // Mixer
    private readonly StereoMixer _mixer = new();

    // Reconciles the loopback endpoint's mix format to the configured shape.
    // Rebuilt for every source installed; written under _systemLock and _lock.
    private SystemAudioNormalizer? _systemNormalizer;

    // Buffers for mixing (protected by _lock)
    private readonly List<float> _micBuffer = [];
    private readonly List<float> _systemBuffer = [];

    // Timing
    private readonly Stopwatch _durationStopwatch = new();
    private TaskCompletionSource<RecordingResult>? _stopTcs;
    private Timer? _maxDurationTimer;

    // The mix loop. A single pump task drives every mix/write, which is what keeps
    // writes serialized — see RunMixPumpAsync.
    private PeriodicTimer? _mixTimer;
    private Task? _mixPump;
    private CancellationTokenSource? _mixCts;

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
    /// it — not in <see cref="Configure"/>, not in <see cref="StartCaptureAsync"/>,
    /// not on a device change. That total avoidance is the requirement, not an
    /// optimization: headless runners have no audio endpoints, and merely enumerating
    /// them there throws. A device change re-invokes the factory instead.
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
                    BufferedSamples = _micBuffer.Count + _systemBuffer.Count,
                    MicSampleRate = _micFormat?.SampleRate ?? 0,
                    MicChannels = _micFormat?.Channels ?? 0,
                    MicBitsPerSample = _micFormat?.BitsPerSample ?? 0,
                    MicEncoding = _micFormat?.Encoding.ToString(),
                    MicMeasuredSampleRate = MeasuredMicRate(),
                    SidecarSampleRate = _config is { } config ? (int)config.SampleRate : 0,
                    SystemPaddedFrames = _systemPaddedFrames,
                    SystemTrimmedFrames = _systemTrimmedFrames,
                    SystemSourceSwitches = _systemSourceSwitches,
                    SystemSourceErrors = _systemSourceErrors,
                    SystemDeviceId = _systemDeviceId,
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
            // would still fail here. The default is the Communications-role capture
            // device: the one the user picked for calls, which is what a session is.
            if (configuration.EnableMicCapture && _micFactory == null)
            {
                using var enumerator = new MMDeviceEnumerator();
                _micDevice = configuration.MicDeviceId != null
                    ? enumerator.GetDevice(configuration.MicDeviceId)
                    : enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);

                if (_micDevice == null)
                    throw CaptureException.DeviceNotAvailable("No microphone device found");
                _micDeviceId = _micDevice.ID;
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
        if (config.ExportRawPcm)
        {
            var pcmExt = config.Encryptor != null ? "enc.pcm" : "pcm";
            if (config.EnableMicCapture)
            {
                var micPcmPath = config.MicSidecarPath
                    ?? Path.Combine(config.OutputDirectory, $"recording_{timestamp}_mic.{pcmExt}");
                // i16 mono: an appended plaintext file is cut back to a whole sample.
                _micSidecar = new SidecarStreamWriter(
                    micPcmPath, config.Encryptor, config.AppendToSidecars, plaintextAlignment: 2);
            }
            if (config.EnableSystemCapture)
            {
                var systemPcmPath = config.SystemSidecarPath
                    ?? Path.Combine(config.OutputDirectory, $"recording_{timestamp}_system.{pcmExt}");
                // i16 stereo: an appended plaintext file is cut back to a whole frame.
                _systemSidecar = new SidecarStreamWriter(
                    systemPcmPath, config.Encryptor, config.AppendToSidecars, plaintextAlignment: 4);
            }
        }

        // The capture clock starts before the sources do, so their first buffers land
        // inside it. It drives duration, and the system-padding reference when there
        // is no mic.
        _durationStopwatch.Restart();

        // Real endpoints get one enumerator for the session, plus an endpoint-change
        // subscription when anything can act on it. Injected sources never touch it.
        var usesRealMic = config.EnableMicCapture && _micFactory == null && _micDevice != null;
        var usesRealLoopback = config.EnableSystemCapture && _systemFactory == null;
        if (usesRealMic || usesRealLoopback)
            StartEndpointWatcher(subscribe: usesRealMic || config.FollowDefaultOutputDevice);

        // Start mic capture. An injected factory stands in for the endpoint, so
        // there's no _micDevice to require in that case.
        if (config.EnableMicCapture && (_micFactory != null || _micDevice != null))
        {
            _micCapture = _micFactory?.Invoke() ?? CreateWasapiMic(config);
            lock (_lock) _micFormat = _micCapture.WaveFormat;
            _micCapture.DataAvailable += OnMicDataAvailable;
            _micCapture.RecordingStopped += OnMicRecordingStopped;
            _micCapture.StartRecording();
        }

        // Start system loopback capture
        if (config.EnableSystemCapture)
        {
            lock (_systemLock) _systemLastDataTimestamp = Stopwatch.GetTimestamp();
            try
            {
                var (source, deviceId) = CreateSystemSource(config.FollowDefaultOutputDevice);
                InstallSystemSource(source, deviceId);
                source.StartRecording();
            }
            catch (Exception ex) when (config.FollowDefaultOutputDevice && _systemFactory == null)
            {
                // No usable output device right now. With following on this isn't fatal:
                // the system channel is held on the clock with silence, and loopback
                // opens as soon as a default output device appears.
                ReportSystemUnavailable("start", ex);
            }
        }

        // Start the mix loop (every 100ms, mix buffered audio and write)
        _mixCts = new CancellationTokenSource();
        _mixTimer = new PeriodicTimer(TimeSpan.FromMilliseconds(100));
        _mixPump = Task.Run(() => RunMixPumpAsync(_mixTimer, _mixCts.Token));

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

    public async Task<RecordingResult> StopCaptureAsync()
    {
        lock (_lock)
        {
            if (_state.Kind != CaptureStateKind.Capturing && _state.Kind != CaptureStateKind.Paused)
                throw CaptureException.ConfigurationFailed($"Cannot stop in state {_state.Kind}");

            _durationStopwatch.Stop();
            TransitionTo(CaptureState.Stopping);
        }

        _maxDurationTimer?.Dispose();
        _maxDurationTimer = null;

        // Let an in-flight device re-open finish (it sees Stopping and stands down), so
        // the source stopped below is the one that stays stopped.
        await WaitForReopensAsync().ConfigureAwait(false);

        // Stop the sources first so no new samples arrive, then drain the pump. Only
        // once the drain returns is this thread the sole writer, which is what makes
        // the final flush and Close below safe.
        _micCapture?.StopRecording();
        IWaveIn? systemCapture;
        lock (_systemLock) systemCapture = _systemCapture;
        systemCapture?.StopRecording();

        await StopMixPumpAsync().ConfigureAwait(false);

        // Flush remaining buffered audio
        MixAndWrite(flush: true);

        // Close writers
        var checksum = _wavWriter?.Close() ?? "";

        // Close the sidecars. A handler still running as we stop has its write dropped
        // by the writer rather than landing in a disposed stream.
        var rawPcmPaths = CloseSidecars();

        var config = _config!;
        var duration = _durationStopwatch.Elapsed;
        var filePath = _wavFilePath ?? "";

        var (tracks, channelLayout) = BuildTrackMetadata(config);

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
            RawPcmFilePaths: rawPcmPaths);

        // Clean up NAudio resources
        DisposeCapture();

        lock (_lock)
        {
            TransitionTo(CaptureState.Completed(result));
        }

        Delegate?.OnCaptureFinished(result);
        _stopTcs?.TrySetResult(result);

        return result;
    }

    public Task<AudioSource[]> GetAvailableAudioSourcesAsync() =>
        Task.FromResult(DeviceEnumerator.GetAllDevices());

    public void Dispose()
    {
        // A session disposed without a stop can still have a pump running. Wait it out
        // before the writers go away underneath it. After a normal stop the pump is
        // already drained and this is a no-op. The pump never captures a sync context,
        // so the wait cannot deadlock on one.
        //
        // Best effort throughout: Dispose must not throw, and racing a concurrent stop
        // can hand us an already-disposed source or a faulted pump.
        try
        {
            _mixCts?.Cancel();
            _mixTimer?.Dispose();
            _mixPump?.Wait(TimeSpan.FromSeconds(5));
            _mixCts?.Dispose();
        }
        catch
        {
            // A faulted pump has already reported via OnError.
        }

        _maxDurationTimer?.Dispose();
        DisposeCapture();
        _wavWriter?.Dispose();
        try
        {
            CloseSidecars();
        }
        catch
        {
            // Best effort: Dispose must not throw.
        }
    }

    // --- Device following ---

    /// <summary>
    /// Endpoint notification: the default device for a flow/role changed. Only the
    /// <c>Console</c> render default is followed. Returns the scheduled re-open (or a
    /// completed task) so tests can await it; the COM callback discards it.
    /// </summary>
    internal Task HandleDefaultDeviceChanged(DataFlow flow, Role role, string? defaultDeviceId)
    {
        if (flow != DataFlow.Render || role != Role.Console) return Task.CompletedTask;
        if (_config is not { FollowDefaultOutputDevice: true, EnableSystemCapture: true }) return Task.CompletedTask;
        if (!IsCaptureActive()) return Task.CompletedTask;

        // Already capturing that endpoint. Injected sources have no id, so any change
        // re-runs their factory.
        if (_systemFactory == null && defaultDeviceId != null && defaultDeviceId == CurrentSystemDeviceId())
            return Task.CompletedTask;

        return ScheduleSystemReopen("default-device-changed", TimeSpan.Zero);
    }

    /// <summary>
    /// Endpoint notification: a device changed state (or was removed). Losing the mic
    /// is reported; losing the output device being captured re-opens loopback on the
    /// current default when following is on.
    /// </summary>
    internal Task HandleDeviceStateChanged(string deviceId, DeviceState newState)
    {
        if (newState == DeviceState.Active || !IsCaptureActive()) return Task.CompletedTask;

        if (_micDeviceId != null && deviceId == _micDeviceId)
            Delegate?.OnDeviceChanged(new CaptureDeviceChange(
                CaptureDeviceChangeKind.MicDisconnected, deviceId, "device-state-changed"));

        if (_config?.FollowDefaultOutputDevice == true && deviceId == CurrentSystemDeviceId())
            return ScheduleSystemReopen("device-state-changed", TimeSpan.Zero);

        return Task.CompletedTask;
    }

    private string? CurrentSystemDeviceId()
    {
        lock (_lock) return _systemDeviceId;
    }

    private bool IsCaptureActive()
    {
        lock (_lock) return _state.Kind is CaptureStateKind.Capturing or CaptureStateKind.Paused;
    }

    /// <summary>Queues a re-open after any already in flight, so swaps never overlap.</summary>
    private Task ScheduleSystemReopen(string reason, TimeSpan delay)
    {
        lock (_reopenLock)
        {
            _reopenChain = _reopenChain
                .ContinueWith(
                    _ => ReopenSystemCaptureAsync(reason, delay),
                    CancellationToken.None,
                    TaskContinuationOptions.None,
                    TaskScheduler.Default)
                .Unwrap();
            return _reopenChain;
        }
    }

    private async Task WaitForReopensAsync()
    {
        Task chain;
        lock (_reopenLock) chain = _reopenChain;
        try
        {
            await chain.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        }
        catch
        {
            // A re-open that failed has already reported; one that hangs is not
            // allowed to hold the stop hostage.
        }
    }

    /// <summary>
    /// Re-opens system capture in place: same writers, same sidecar, fresh source and
    /// normalizer (the new device may run a different mix format). The gap while no
    /// source is installed is padded by the mix pump like any other silence.
    /// </summary>
    private async Task ReopenSystemCaptureAsync(string reason, TimeSpan delay)
    {
        if (delay > TimeSpan.Zero)
            await Task.Delay(delay).ConfigureAwait(false);
        if (!IsCaptureActive()) return;

        var follow = _config?.FollowDefaultOutputDevice == true;
        IWaveIn? replacement = null;
        try
        {
            var (source, deviceId) = CreateSystemSource(follow);
            replacement = source;

            IWaveIn? old;
            lock (_systemLock)
            {
                old = _systemCapture;
                if (old != null)
                {
                    old.DataAvailable -= OnSystemDataAvailable;
                    old.RecordingStopped -= OnSystemRecordingStopped;
                }
                _systemCapture = null;
            }

            if (old != null)
            {
                try
                {
                    old.StopRecording();
                    old.Dispose();
                }
                catch
                {
                    // An invalidated endpoint can fail its own teardown; it is detached
                    // already and nothing more is wanted from it.
                }
            }

            if (!IsCaptureActive())
            {
                source.Dispose();
                return;
            }

            InstallSystemSource(source, deviceId);
            source.StartRecording();

            lock (_lock) _systemSourceSwitches++;
            Delegate?.OnDeviceChanged(new CaptureDeviceChange(
                CaptureDeviceChangeKind.SystemOutputSwitched, deviceId, reason));
        }
        catch (Exception ex)
        {
            if (replacement != null)
            {
                lock (_systemLock)
                {
                    if (ReferenceEquals(_systemCapture, replacement))
                    {
                        replacement.DataAvailable -= OnSystemDataAvailable;
                        replacement.RecordingStopped -= OnSystemRecordingStopped;
                        _systemCapture = null;
                    }
                }
                try { replacement.Dispose(); } catch { /* best effort */ }
            }
            ReportSystemUnavailable(reason, ex);
        }
    }

    private void ReportSystemUnavailable(string reason, Exception ex)
    {
        Delegate?.OnError(CaptureException.DeviceNotAvailable($"System audio unavailable: {ex.Message}"));
        Delegate?.OnDeviceChanged(new CaptureDeviceChange(
            CaptureDeviceChangeKind.SystemOutputUnavailable, null, reason));
    }

    /// <summary>
    /// Builds the system-audio source: the injected factory when there is one, else
    /// loopback on the default render device — the <c>Console</c> default when
    /// following (the one browsers and most apps render to), the <c>Multimedia</c>
    /// default otherwise, which is what NAudio's parameterless loopback opens.
    /// </summary>
    private (IWaveIn Source, string? DeviceId) CreateSystemSource(bool follow)
    {
        if (_systemFactory != null)
            return (_systemFactory(), null);

        var enumerator = _enumerator ?? throw CaptureException.DeviceNotAvailable("No endpoint enumerator");
        var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, follow ? Role.Console : Role.Multimedia)
            ?? throw CaptureException.DeviceNotAvailable("No output device found");
        return (new WasapiLoopbackCapture(device), device.ID);
    }

    /// <summary>
    /// Makes <paramref name="source"/> the current system source and builds its
    /// normalizer — before the first callback can fire, since the endpoint's format is
    /// only knowable now and the data handler relies on both.
    /// </summary>
    private void InstallSystemSource(IWaveIn source, string? deviceId)
    {
        var format = source.WaveFormat;
        var normalizer = new SystemAudioNormalizer(format.SampleRate, format.Channels, (int)_config!.SampleRate);
        lock (_systemLock)
        {
            _systemCapture = source;
            _systemFormat = format;
            lock (_lock)
            {
                _systemNormalizer = normalizer;
                _systemDeviceId = deviceId;
            }
            source.DataAvailable += OnSystemDataAvailable;
            source.RecordingStopped += OnSystemRecordingStopped;
        }
    }

    private void StartEndpointWatcher(bool subscribe)
    {
        _enumerator = new MMDeviceEnumerator();
        if (!subscribe) return;
        try
        {
            var watcher = new EndpointWatcher(this);
            _enumerator.RegisterEndpointNotificationCallback(watcher);
            _endpointWatcher = watcher;
        }
        catch (Exception ex)
        {
            // Capture still works without notifications; it just can't follow.
            Delegate?.OnError(CaptureException.DeviceNotAvailable($"Endpoint notifications unavailable: {ex.Message}"));
        }
    }

    private void StopEndpointWatcher()
    {
        var enumerator = _enumerator;
        var watcher = _endpointWatcher;
        _enumerator = null;
        _endpointWatcher = null;
        if (enumerator == null) return;
        try
        {
            if (watcher != null)
                enumerator.UnregisterEndpointNotificationCallback(watcher);
            enumerator.Dispose();
        }
        catch
        {
            // Best effort: teardown must not throw.
        }
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
            _micFramesCaptured += samples.Length / Math.Max(1, _micFormat?.Channels ?? 1);
            TrackPeakBuffered();
        }

        // Write raw PCM sidecar (encrypted if encryptor configured)
        _micSidecar?.Write(e.Buffer.AsSpan(0, e.BytesRecorded));
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

        float[] samples;
        lock (_systemLock)
        {
            // A buffer from a source that has since been swapped out is in the old
            // device's format, which the current normalizer can't read. Drop it — the
            // swap gap is padded anyway.
            if (sender != null && !ReferenceEquals(sender, _systemCapture)) return;
            var format = _systemFormat;
            var normalizer = _systemNormalizer;
            if (format == null || normalizer == null) return;

            // System loopback is typically 32-bit float stereo — convert as needed
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
            samples = normalizer.Normalize(captured);

            _systemLastDataTimestamp = Stopwatch.GetTimestamp();
            _systemRetryAttempts = 0;

            samples = TrimOvershoot(samples);
            if (samples.Length == 0) return;
            EmitSystemSamples(samples);
        }

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
    }

    /// <summary>
    /// Hands normalized system frames (interleaved stereo at the configured rate) to
    /// the mix buffer and the sidecar, and counts them against the clock. The one way
    /// frames enter the system channel — real audio and padding alike — so the mixed
    /// WAV and the sidecar can't disagree. Must hold <see cref="_systemLock"/>.
    /// </summary>
    private void EmitSystemSamples(float[] samples)
    {
        lock (_lock)
        {
            _systemBuffer.AddRange(samples);
            TrackPeakBuffered();
        }
        _systemEmittedFrames += samples.Length / SystemAudioNormalizer.TargetChannels;

        // Raw PCM sidecar as i16 LE (matching macOS format), encrypted if configured.
        _systemSidecar?.Write(ConvertFloatToInt16Pcm(samples));
    }

    /// <summary>
    /// The frame count the system channel should have reached by now, at the
    /// configured rate. The mic is the primary clock, as on macOS: the two sidecars
    /// have to line up with each other, and a wall clock drifts against the mic's
    /// device clock where the mic itself does not. With no mic, the pause-aware
    /// session stopwatch stands in.
    /// </summary>
    private long SystemReferenceFrames()
    {
        var config = _config!;
        lock (_lock)
        {
            if (config.EnableMicCapture && _micFormat != null)
                return (long)(_micFramesCaptured * (config.SampleRate / _micFormat.SampleRate));
        }
        return (long)(_durationStopwatch.Elapsed.TotalSeconds * config.SampleRate);
    }

    /// <summary>
    /// Pads the system channel with silence up to its reference when loopback has
    /// been quiet longer than <see cref="SystemGapThreshold"/>, or unconditionally at
    /// the final flush. Runs on the mix pump, so padding is in the sample domain and
    /// takes the same path as real audio.
    /// </summary>
    private void PadSystemGap(bool final)
    {
        if (_config is not { EnableSystemCapture: true } config) return;

        lock (_systemLock)
        {
            if (!final)
            {
                lock (_lock)
                {
                    if (_state.Kind != CaptureStateKind.Capturing) return;
                }
                if (Stopwatch.GetElapsedTime(_systemLastDataTimestamp) < SystemGapThreshold) return;
            }

            var deficit = SystemReferenceFrames() - _systemEmittedFrames;
            if (deficit <= 0) return;

            // At most a second per chunk, so a long gap doesn't become one huge write.
            var maxChunkFrames = (long)config.SampleRate;
            var remaining = deficit;
            while (remaining > 0)
            {
                var frames = (int)Math.Min(remaining, maxChunkFrames);
                EmitSystemSamples(new float[frames * SystemAudioNormalizer.TargetChannels]);
                remaining -= frames;
            }

            _systemPadCredit += deficit;
            lock (_lock) _systemPaddedFrames += deficit;
        }
    }

    /// <summary>
    /// Silence padded during a quiet stretch can turn out to have been a late delivery
    /// rather than a gap — a stalled capture thread that then catches up in a burst.
    /// When real frames would push the channel past its reference by more than
    /// <see cref="SystemOvershootTolerance"/>, drop the excess from the front of the
    /// buffer, never more than was padded: real audio is only traded against silence
    /// this session fabricated. Must hold <see cref="_systemLock"/>.
    /// </summary>
    private float[] TrimOvershoot(float[] samples)
    {
        if (_systemPadCredit <= 0) return samples;

        const int channels = SystemAudioNormalizer.TargetChannels;
        var frames = samples.Length / channels;
        var tolerance = (long)(_config!.SampleRate * SystemOvershootTolerance.TotalSeconds);
        var overshoot = _systemEmittedFrames + frames - SystemReferenceFrames() - tolerance;
        if (overshoot <= 0) return samples;

        var drop = (int)Math.Min(Math.Min(overshoot, _systemPadCredit), frames);
        _systemPadCredit -= drop;
        lock (_lock) _systemTrimmedFrames += drop;
        return drop == frames ? [] : samples[(drop * channels)..];
    }

    /// <summary>
    /// Drives mixing on one task, so a tick's mix and write always complete before
    /// the next tick begins. Serializing here is what makes the writes safe: encrypt
    /// plus disk write has no obligation to fit inside the 100ms interval, and two
    /// ticks interleaving in the writer would desync the length-prefix framing and
    /// cost every byte after the tear.
    ///
    /// A tick that overruns delays the next one instead of racing it; the sample
    /// buffers hold the surplus and the following mix picks it up.
    /// </summary>
    private async Task RunMixPumpAsync(PeriodicTimer timer, CancellationToken ct)
    {
        try
        {
            while (await timer.WaitForNextTickAsync(ct).ConfigureAwait(false))
                MixAndWrite();
        }
        catch (OperationCanceledException)
        {
            // Stop asked for the pump to end; the stopping thread does the final flush.
        }
    }

    /// <summary>
    /// Ends the mix loop and waits out any in-flight mix. This is a barrier: once it
    /// returns, no other thread is inside the writer, which is what lets the caller
    /// flush and close the file safely. Disposing the timer alone would not wait —
    /// it would leave a tick running into a closed writer.
    /// </summary>
    private async Task StopMixPumpAsync()
    {
        _mixCts?.Cancel();
        _mixTimer?.Dispose();

        if (_mixPump != null)
        {
            try
            {
                await _mixPump.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                // Expected on cancellation.
            }
        }

        _mixPump = null;
        _mixTimer = null;
        _mixCts?.Dispose();
        _mixCts = null;
    }

    private void MixAndWrite(bool flush = false)
    {
        // Keep the system channel on the clock before deciding what to consume, so a
        // silent loopback is mixed as silence rather than left to the stall guard.
        PadSystemGap(final: flush);

        float[] mic;
        float[] system;

        lock (_lock)
        {
            var micFrames = _micBuffer.Count;
            var systemFrames = _systemBuffer.Count / 2;

            // Consume mic and system in lockstep, leaving the remainder for the next
            // cycle. Draining both buffers to empty and padding the shorter to max()
            // each cycle — as this did before — fabricates silence on whichever side
            // lagged and walks the two streams out of alignment over a long session.
            // Taking the common minimum and carrying the rest keeps them frame-locked.
            // ResolveFramesToConsume bounds a genuinely stalled partner; flush drains
            // whatever is left at stop, where a final ragged edge is unavoidable and
            // harmless.
            var frames = ResolveFramesToConsume(micFrames, systemFrames, flush);
            if (frames == 0) return;

            mic = TakeFront(_micBuffer, Math.Min(frames, micFrames));
            system = TakeFront(_systemBuffer, Math.Min(frames, systemFrames) * 2);
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
    /// How many frames this mix cycle should consume from each buffer, keeping mic and
    /// system aligned: take the common minimum, carry the remainder, so the two stay
    /// frame-locked and neither is padded with fabricated silence.
    ///
    /// Symmetric — whichever side leads is the one held back. This diverges from
    /// macOS's readPendingSamples, which treats mic as the primary clock and only
    /// zero-fills a fully-empty system buffer. The extra symmetry is deliberate: these
    /// are growable List buffers, not macOS's drop-on-overflow ring buffers, so a
    /// partner that stalls has to be bounded here rather than by overflow — and it
    /// covers a stalled mic, which macOS handles not at all. A silent loopback no
    /// longer reaches this guard: <see cref="PadSystemGap"/> fills it first. Must hold
    /// <see cref="_lock"/>.
    /// </summary>
    private int ResolveFramesToConsume(int micFrames, int systemFrames, bool flush)
    {
        // End of capture: take whatever is left in one pass; Mix zero-pads the ragged
        // tail, which is a few ms at most and has no next cycle to align to.
        if (flush)
            return Math.Max(micFrames, systemFrames);

        // A partner behind by less than this is merely late — wait for it and stay
        // aligned. Beyond it, treat it as stalled. Kept generous on purpose: firing
        // early on a still-arriving partner would zero-fill a gap and re-introduce the
        // very misalignment this method exists to prevent. The cost of waiting is
        // bounded buffering (0.5s ~ 192 KB of floats); the cost of firing early is
        // permanent skew, so err toward waiting.
        const int stallGuard = 24000; // 0.5s at the configured 48 kHz

        var micEnabled = _config?.EnableMicCapture ?? false;
        var systemEnabled = _config?.EnableSystemCapture ?? false;

        // Single-source: that source is the clock, nothing to align against — drain it.
        if (!micEnabled)
            return systemFrames;
        if (!systemEnabled)
            return micFrames;

        // Steady state: consume the aligned common minimum and carry the remainder.
        //
        // Guard: if one side has surged more than stallGuard ahead of the other, its
        // partner has stalled (a device hiccup, or the injected pump losing its thread
        // under test load) and draining only the common minimum would let the leading
        // side grow without bound. Drain the whole surplus, letting Mix zero-fill the
        // stalled side, so the buffer clears in one cycle. In the steady state the
        // surplus is negative and this reduces to the plain aligned minimum.
        var aligned = Math.Min(micFrames, systemFrames);
        var surplus = Math.Max(micFrames, systemFrames) - stallGuard;
        return Math.Max(aligned, Math.Max(surplus, 0));
    }

    /// <summary>
    /// Removes and returns the first <paramref name="count"/> items, leaving the rest
    /// in place for the next cycle. Must hold <see cref="_lock"/>.
    /// </summary>
    private static float[] TakeFront(List<float> buffer, int count)
    {
        if (count <= 0) return [];
        var taken = new float[count];
        buffer.CopyTo(0, taken, 0, count);
        buffer.RemoveRange(0, count);
        return taken;
    }

    /// <summary>
    /// Describes the tracks and channel layout the mix actually produced, so the
    /// backend isn't told it can split speakers by channel when it can't. Mirrors
    /// macOS finalizeRecording:
    /// <list type="bullet">
    /// <item>Separated (and reserved Multichannel): L = mic, R = system mono-fold, so
    /// mic is Left and system is Right — genuinely channel-separated.</item>
    /// <item>Blended: mic is summed into both channels (phantom Center) while system
    /// keeps its stereo image, so neither source owns a channel.</item>
    /// </list>
    /// The tracks stay gated on which sources are enabled.
    /// </summary>
    private static (AudioTrack[] Tracks, ChannelLayout Layout) BuildTrackMetadata(CaptureConfiguration config)
    {
        var separated = config.MixingStrategy is MixingStrategy.Separated or MixingStrategy.Multichannel;

        var tracks = new List<AudioTrack>();
        if (config.EnableMicCapture)
            tracks.Add(separated
                ? new AudioTrack(AudioTrackType.Mic, AudioChannel.Left, "Mic (Local)")
                : new AudioTrack(AudioTrackType.Mic, AudioChannel.Center, null));
        if (config.EnableSystemCapture)
            tracks.Add(separated
                ? new AudioTrack(AudioTrackType.System, AudioChannel.Right, "System (Remote, mono-fold)")
                : new AudioTrack(AudioTrackType.System, AudioChannel.Stereo, null));

        var layout = separated ? ChannelLayout.SeparatedStereo : ChannelLayout.Blended;
        return ([.. tracks], layout);
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

    /// <summary>
    /// Mic frames delivered per second of capture time. Must hold <see cref="_lock"/>.
    /// </summary>
    private double MeasuredMicRate()
    {
        var seconds = _durationStopwatch.Elapsed.TotalSeconds;
        return seconds >= 1.0 ? _micFramesCaptured / seconds : 0;
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
        if (e.Exception == null) return;

        int attempt;
        lock (_systemLock)
        {
            // A source already swapped out reporting its own teardown is not news.
            if (sender != null && !ReferenceEquals(sender, _systemCapture)) return;
            attempt = ++_systemRetryAttempts;
        }
        lock (_lock) _systemSourceErrors++;

        Delegate?.OnError(CaptureException.DeviceNotAvailable($"System audio stopped: {e.Exception.Message}"));

        // With following on, try to get loopback back (an endpoint is invalidated by a
        // route or format change). Backs off per attempt and gives up after a few; the
        // system channel stays on the clock with silence either way.
        if (_config?.FollowDefaultOutputDevice == true && attempt <= MaxSystemRetries && IsCaptureActive())
            _ = ScheduleSystemReopen("capture-error", TimeSpan.FromMilliseconds(500 * attempt));
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

        IWaveIn? system;
        lock (_systemLock)
        {
            system = _systemCapture;
            _systemCapture = null;
            if (system != null)
            {
                system.DataAvailable -= OnSystemDataAvailable;
                system.RecordingStopped -= OnSystemRecordingStopped;
            }
        }
        system?.Dispose();

        StopEndpointWatcher();
        _micDevice = null;
    }

    /// <summary>Closes both sidecars and returns the paths that exist, mic first.</summary>
    private string[] CloseSidecars()
    {
        var paths = new List<string>();
        foreach (var sidecar in new[] { _micSidecar, _systemSidecar })
        {
            if (sidecar == null) continue;
            sidecar.Close();
            if (File.Exists(sidecar.FilePath)) paths.Add(sidecar.FilePath);
        }
        return [.. paths];
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

    /// <summary>
    /// Forwards Core Audio endpoint notifications to the session. Called on a COM
    /// worker thread that must not block or throw, so each handler only schedules.
    /// </summary>
    private sealed class EndpointWatcher(WasapiCaptureSession session) : IMMNotificationClient
    {
        public void OnDeviceStateChanged(string deviceId, DeviceState newState) =>
            Guard(() => session.HandleDeviceStateChanged(deviceId, newState));

        public void OnDeviceAdded(string pwstrDeviceId)
        {
        }

        public void OnDeviceRemoved(string deviceId) =>
            Guard(() => session.HandleDeviceStateChanged(deviceId, DeviceState.NotPresent));

        public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId) =>
            Guard(() => session.HandleDefaultDeviceChanged(flow, role, defaultDeviceId));

        public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key)
        {
        }

        private static void Guard(Func<Task> handler)
        {
            try { _ = handler(); }
            catch { /* never throw back into Core Audio */ }
        }
    }
}
