namespace AudioCapture.Models;

/// <summary>
/// Real-time audio level metering data (0.0 to 1.0).
/// </summary>
public sealed record AudioLevels(
    float MicLevel,
    float SystemLevel,
    float PeakMicLevel,
    float PeakSystemLevel)
{
    public static readonly AudioLevels Zero = new(0f, 0f, 0f, 0f);
}
