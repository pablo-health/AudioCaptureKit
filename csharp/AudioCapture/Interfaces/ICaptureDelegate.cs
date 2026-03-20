using AudioCapture.Models;

namespace AudioCapture.Interfaces;

/// <summary>
/// Receives callbacks from a capture session. Mirrors Swift AudioCaptureDelegate.
/// </summary>
public interface ICaptureDelegate
{
    void OnStateChanged(CaptureState state);
    void OnLevelsUpdated(AudioLevels levels);
    void OnError(CaptureException error);
    void OnCaptureFinished(RecordingResult result);
}
