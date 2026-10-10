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

    /// <summary>
    /// Re-open the system-audio loopback in place when the Windows default output
    /// device changes (headset plugged in, Bluetooth connecting, a call app switching
    /// speakers) or the current one goes away, and retry it after a loopback error.
    /// The writers and sidecars stay open across the switch. Follows the
    /// <c>Console</c>-role default render device. Off by default, which keeps the
    /// original pinned-at-start behaviour.
    /// </summary>
    public bool FollowDefaultOutputDevice { get; init; }

    /// <summary>
    /// Explicit path for the mic sidecar instead of the timestamp-derived one. Required
    /// to append to a sidecar from an earlier capture (see <see cref="AppendToSidecars"/>).
    /// </summary>
    public string? MicSidecarPath { get; init; }

    /// <summary>Explicit path for the system-audio sidecar instead of the timestamp-derived one.</summary>
    public string? SystemSidecarPath { get; init; }

    /// <summary>
    /// Continue existing sidecar files instead of truncating them. Encrypted sidecars
    /// are a sequence of self-delimiting sealed chunks, so the runs concatenate into one
    /// decryptable stream; a torn final chunk from an interrupted run is repaired first.
    /// Use with <see cref="MicSidecarPath"/>/<see cref="SystemSidecarPath"/>. The mixed
    /// WAV is always written fresh.
    /// </summary>
    public bool AppendToSidecars { get; init; }
}
