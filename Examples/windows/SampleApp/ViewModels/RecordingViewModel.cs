using System.Collections.ObjectModel;
using System.Diagnostics;
using AudioCapture.Capture;
using AudioCapture.Interfaces;
using AudioCapture.Models;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using SampleApp.Services;

namespace SampleApp.ViewModels;

public sealed record RecordingInfo(
    string FilePath,
    string FileName,
    long SizeBytes,
    bool IsEncrypted,
    DateTime CreatedAt);

public partial class RecordingViewModel : ObservableObject, ICaptureDelegate, IDisposable
{
    private readonly DispatcherQueue _dispatcher;
    private WasapiCaptureSession? _session;
    private DispatcherQueueTimer? _levelTimer;
    private DispatcherQueueTimer? _durationTimer;
    private DateTime _captureStartTime;
    private TimeSpan _pausedAccumulated;
    private DateTime _pauseStartTime;

    // Settings
    [ObservableProperty] public partial string? SelectedMicId { get; set; }
    [ObservableProperty] public partial string MixingStrategy { get; set; } = "Blended";
    [ObservableProperty] public partial bool EncryptionEnabled { get; set; }
    [ObservableProperty] public partial bool ExportRawPcm { get; set; }
    [ObservableProperty] public partial bool EnableMic { get; set; } = true;
    [ObservableProperty] public partial bool EnableSystem { get; set; } = true;

    // State
    [ObservableProperty] public partial string State { get; set; } = "Idle";
    [ObservableProperty] public partial string Duration { get; set; } = "00:00";
    [ObservableProperty] public partial float MicLevel { get; set; }
    [ObservableProperty] public partial float SystemLevel { get; set; }
    [ObservableProperty] public partial float PeakMicLevel { get; set; }
    [ObservableProperty] public partial float PeakSystemLevel { get; set; }
    [ObservableProperty] public partial string? ErrorMessage { get; set; }
    [ObservableProperty] public partial bool IsActive { get; set; }

    // Diagnostics (visible during recording)
    [ObservableProperty] public partial string MicLevelText { get; set; } = "0.0000";
    [ObservableProperty] public partial string SystemLevelText { get; set; } = "0.0000";

    // Devices
    [ObservableProperty] public partial AudioSource[] AvailableMics { get; set; } = [];

    // Recordings
    public ObservableCollection<RecordingInfo> Recordings { get; } = [];

    private static string RecordingsDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            "AudioCaptureKit Recordings");

    public RecordingViewModel(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
    }

    public async Task LoadDevicesAsync()
    {
        using var session = new WasapiCaptureSession();
        AvailableMics = await session.GetAvailableAudioSourcesAsync();
    }

    public void RefreshRecordings()
    {
        Recordings.Clear();
        var dir = RecordingsDir;
        if (!Directory.Exists(dir)) return;

        var files = Directory.GetFiles(dir, "recording_*.*")
            .Where(f => f.EndsWith(".wav", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(File.GetCreationTime)
            .ToArray();

        foreach (var file in files)
        {
            var info = new FileInfo(file);
            Recordings.Add(new RecordingInfo(
                file,
                info.Name,
                info.Length,
                info.Name.Contains(".enc.", StringComparison.OrdinalIgnoreCase),
                info.CreationTime));
        }
    }

    [RelayCommand]
    private async Task StartRecordingAsync()
    {
        ErrorMessage = null;

        try
        {
            State = "Configuring";
            IsActive = true;

            _session = new WasapiCaptureSession();
            _session.Delegate = this;

            var strategy = MixingStrategy switch
            {
                "Separated" => AudioCapture.Models.MixingStrategy.Separated,
                _ => AudioCapture.Models.MixingStrategy.Blended,
            };

            ICaptureEncryptor? encryptor = EncryptionEnabled ? new DemoEncryptor() : null;

            var config = new CaptureConfiguration
            {
                Encryptor = encryptor,
                OutputDirectory = RecordingsDir,
                MicDeviceId = SelectedMicId,
                EnableMicCapture = EnableMic,
                EnableSystemCapture = EnableSystem,
                MixingStrategy = strategy,
                ExportRawPcm = ExportRawPcm,
            };

            _session.Configure(config);
            State = "Ready";

            // Start level polling
            _levelTimer = _dispatcher.CreateTimer();
            _levelTimer.Interval = TimeSpan.FromMilliseconds(66);
            _levelTimer.Tick += (_, _) => PollLevels();
            _levelTimer.Start();

            // Start duration timer
            _captureStartTime = DateTime.UtcNow;
            _pausedAccumulated = TimeSpan.Zero;
            _durationTimer = _dispatcher.CreateTimer();
            _durationTimer.Interval = TimeSpan.FromMilliseconds(250);
            _durationTimer.Tick += (_, _) => UpdateDuration();
            _durationTimer.Start();

            // Fire and forget — capture runs until stop
            _ = _session.StartCaptureAsync().ContinueWith(t =>
            {
                if (t.IsFaulted)
                    _dispatcher.TryEnqueue(() => ErrorMessage = t.Exception?.InnerException?.Message);
            });

            State = "Capturing";
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            State = "Failed";
            IsActive = false;
        }

        await Task.CompletedTask;
    }

    [RelayCommand]
    private void PauseRecording()
    {
        if (_session == null) return;
        _session.PauseCapture();
        _pauseStartTime = DateTime.UtcNow;
        State = "Paused";
    }

    [RelayCommand]
    private void ResumeRecording()
    {
        if (_session == null) return;
        _session.ResumeCapture();
        _pausedAccumulated += DateTime.UtcNow - _pauseStartTime;
        State = "Capturing";
    }

    [RelayCommand]
    private async Task StopRecordingAsync()
    {
        if (_session == null) return;

        State = "Stopping";
        StopTimers();

        try
        {
            await _session.StopCaptureAsync();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
        }

        _session.Dispose();
        _session = null;

        State = "Idle";
        IsActive = false;
        Duration = "00:00";
        MicLevel = 0;
        SystemLevel = 0;
        PeakMicLevel = 0;
        PeakSystemLevel = 0;
        MicLevelText = "0.0000";
        SystemLevelText = "0.0000";

        RefreshRecordings();
    }

    [RelayCommand]
    private void OpenRecording(RecordingInfo recording)
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = recording.FilePath,
            UseShellExecute = true,
        });
    }

    [RelayCommand]
    private void DeleteRecording(RecordingInfo recording)
    {
        try
        {
            if (File.Exists(recording.FilePath))
                File.Delete(recording.FilePath);

            // Delete sidecar PCM files
            var baseName = Path.GetFileNameWithoutExtension(recording.FilePath)
                .Replace(".enc", "");
            var dir = Path.GetDirectoryName(recording.FilePath)!;
            foreach (var sidecar in Directory.GetFiles(dir, $"{baseName}*"))
            {
                if (sidecar != recording.FilePath)
                    File.Delete(sidecar);
            }
        }
        catch { }

        Recordings.Remove(recording);
    }

    private void PollLevels()
    {
        if (_session == null) return;
        var levels = _session.CurrentLevels;
        MicLevel = Math.Clamp(levels.MicLevel, 0, 1);
        SystemLevel = Math.Clamp(levels.SystemLevel, 0, 1);
        PeakMicLevel = Math.Clamp(levels.PeakMicLevel, 0, 1);
        PeakSystemLevel = Math.Clamp(levels.PeakSystemLevel, 0, 1);
        MicLevelText = $"{MicLevel:F4}";
        SystemLevelText = $"{SystemLevel:F4}";
    }

    private void UpdateDuration()
    {
        var elapsed = DateTime.UtcNow - _captureStartTime - _pausedAccumulated;
        if (State == "Paused")
            elapsed -= (DateTime.UtcNow - _pauseStartTime);
        if (elapsed < TimeSpan.Zero) elapsed = TimeSpan.Zero;
        Duration = elapsed.TotalHours >= 1
            ? elapsed.ToString(@"hh\:mm\:ss")
            : elapsed.ToString(@"mm\:ss");
    }

    private void StopTimers()
    {
        _levelTimer?.Stop();
        _levelTimer = null;
        _durationTimer?.Stop();
        _durationTimer = null;
    }

    // ICaptureDelegate
    public void OnStateChanged(AudioCapture.Models.CaptureState state) { }
    public void OnLevelsUpdated(AudioLevels levels) { }
    public void OnError(CaptureException error) =>
        _dispatcher.TryEnqueue(() => ErrorMessage = error.Message);
    public void OnCaptureFinished(RecordingResult result) =>
        _dispatcher.TryEnqueue(RefreshRecordings);

    public void Dispose()
    {
        StopTimers();
        _session?.Dispose();
    }
}
