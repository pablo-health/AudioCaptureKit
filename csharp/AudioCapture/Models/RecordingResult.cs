namespace AudioCapture.Models;

/// <summary>
/// Result of a completed recording session.
/// </summary>
public sealed record RecordingResult(
    string FilePath,
    double DurationSecs,
    RecordingMetadata Metadata,
    string Checksum,
    string[] RawPcmFilePaths);
