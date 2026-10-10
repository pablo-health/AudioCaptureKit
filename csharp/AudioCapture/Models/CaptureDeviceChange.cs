namespace AudioCapture.Models;

/// <summary>What happened to a capture endpoint mid-session.</summary>
public enum CaptureDeviceChangeKind
{
    /// <summary>System-audio capture moved to a new output device (or was re-opened on the same one).</summary>
    SystemOutputSwitched,

    /// <summary>Re-opening system-audio capture failed; the system channel is held on the clock with silence.</summary>
    SystemOutputUnavailable,

    /// <summary>The microphone endpoint in use was disconnected, disabled or removed.</summary>
    MicDisconnected,
}

/// <summary>
/// A device event during capture. Carries endpoint ids only — they identify hardware,
/// not anyone being recorded.
/// </summary>
/// <param name="Kind">What changed.</param>
/// <param name="DeviceId">The endpoint now in use (switch) or the one lost; null for an injected source.</param>
/// <param name="Reason">Short machine-oriented cause, e.g. "default-device-changed", "device-state-changed", "capture-error".</param>
public sealed record CaptureDeviceChange(CaptureDeviceChangeKind Kind, string? DeviceId, string Reason);
