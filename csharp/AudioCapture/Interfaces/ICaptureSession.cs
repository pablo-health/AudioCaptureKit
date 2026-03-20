using AudioCapture.Models;

namespace AudioCapture.Interfaces;

/// <summary>
/// Audio capture session interface. Mirrors Swift AudioCaptureSession protocol.
/// </summary>
public interface ICaptureSession : IDisposable
{
    CaptureState State { get; }
    AudioLevels CurrentLevels { get; }
    ICaptureDelegate? Delegate { get; set; }

    void Configure(CaptureConfiguration configuration);
    Task<RecordingResult> StartCaptureAsync();
    void PauseCapture();
    void ResumeCapture();
    Task<RecordingResult> StopCaptureAsync();
    Task<AudioSource[]> GetAvailableAudioSourcesAsync();
}
