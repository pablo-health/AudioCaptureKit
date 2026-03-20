namespace AudioCapture.Models;

/// <summary>
/// Describes a single audio track in a recording.
/// </summary>
public sealed record AudioTrack(AudioTrackType Type, AudioChannel Channel, string? Label);
