namespace AudioCapture.Models;

/// <summary>
/// Describes an available audio input or output device.
/// </summary>
public sealed record AudioSource(
    string Id,
    string Name,
    AudioTrackType SourceType,
    bool IsDefault,
    AudioTransportType? TransportType);
