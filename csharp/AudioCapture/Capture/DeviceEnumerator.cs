using AudioCapture.Models;
using NAudio.CoreAudioApi;

namespace AudioCapture.Capture;

/// <summary>
/// Enumerates available audio devices via NAudio's MMDeviceEnumerator.
/// </summary>
public static class DeviceEnumerator
{
    /// <summary>
    /// Returns all active audio capture (mic) devices.
    /// </summary>
    public static AudioSource[] GetCaptureDevices()
    {
        using var enumerator = new MMDeviceEnumerator();
        var devices = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active);
        var defaultId = GetDefaultDeviceId(enumerator, DataFlow.Capture);

        return devices.Select(d => new AudioSource(
            Id: d.ID,
            Name: d.FriendlyName,
            SourceType: AudioTrackType.Mic,
            IsDefault: d.ID == defaultId,
            TransportType: null
        )).ToArray();
    }

    /// <summary>
    /// Returns all active audio render (system/loopback) devices.
    /// </summary>
    public static AudioSource[] GetRenderDevices()
    {
        using var enumerator = new MMDeviceEnumerator();
        var devices = enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active);
        var defaultId = GetDefaultDeviceId(enumerator, DataFlow.Render);

        return devices.Select(d => new AudioSource(
            Id: d.ID,
            Name: d.FriendlyName,
            SourceType: AudioTrackType.System,
            IsDefault: d.ID == defaultId,
            TransportType: null
        )).ToArray();
    }

    /// <summary>
    /// Returns all available audio sources (mic + system).
    /// </summary>
    public static AudioSource[] GetAllDevices()
    {
        return [.. GetCaptureDevices(), .. GetRenderDevices()];
    }

    private static string? GetDefaultDeviceId(MMDeviceEnumerator enumerator, DataFlow flow)
    {
        try
        {
            return enumerator.GetDefaultAudioEndpoint(flow, Role.Multimedia)?.ID;
        }
        catch
        {
            return null;
        }
    }
}
