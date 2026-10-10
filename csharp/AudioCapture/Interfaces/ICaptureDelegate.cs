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

    /// <summary>
    /// A capture endpoint changed mid-session: system audio followed a new output
    /// device, could not be re-opened, or the mic went away. Optional — the default
    /// does nothing, so existing implementations are unaffected. Errors still arrive
    /// through <see cref="OnError"/> as well.
    /// </summary>
    void OnDeviceChanged(CaptureDeviceChange change)
    {
    }
}
