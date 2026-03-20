namespace AudioCapture.Models;

/// <summary>
/// Strategy for mixing mic and system audio into the stereo output.
/// </summary>
public enum MixingStrategy
{
    /// Mic mixed into both channels: L = mic + sys_L, R = mic + sys_R
    Blended,

    /// Mic on left, system mono-folded on right: L = mic, R = (sys_L + sys_R) / 2
    Separated,

    /// Reserved for future multi-track output.
    Multichannel,
}

/// <summary>
/// Describes the channel layout of a recording.
/// </summary>
public enum ChannelLayout
{
    /// Legacy blended (mic mixed into both channels).
    Blended,

    /// Ch1 = mic, Ch2 = system mono-folded.
    SeparatedStereo,

    /// Single mono channel.
    Mono,
}

/// <summary>
/// Type of audio source track.
/// </summary>
public enum AudioTrackType
{
    Mic,
    System,
}

/// <summary>
/// Physical transport type of an audio device.
/// </summary>
public enum AudioTransportType
{
    BuiltIn,
    Bluetooth,
    BluetoothLE,
    Usb,
    Virtual,
    Unknown,
}

/// <summary>
/// Audio channel assignment.
/// </summary>
public enum AudioChannel
{
    Left,
    Right,
    Center,
    Stereo,
}
