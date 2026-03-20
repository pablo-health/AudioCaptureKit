using AudioCapture.Interfaces;

namespace AudioCapture.Models;

/// <summary>
/// Configuration for an audio capture session. Mirrors Swift CaptureConfiguration.
/// </summary>
public sealed record CaptureConfiguration
{
    public double SampleRate { get; init; } = 48000;
    public int BitDepth { get; init; } = 16;
    public int Channels { get; init; } = 2;
    public ICaptureEncryptor? Encryptor { get; init; }
    public string OutputDirectory { get; init; } = "";
    public TimeSpan? MaxDuration { get; init; }
    public string? MicDeviceId { get; init; }
    public bool EnableMicCapture { get; init; } = true;
    public bool EnableSystemCapture { get; init; } = true;
    public MixingStrategy MixingStrategy { get; init; } = MixingStrategy.Blended;
    public bool ExportRawPcm { get; init; }
}
