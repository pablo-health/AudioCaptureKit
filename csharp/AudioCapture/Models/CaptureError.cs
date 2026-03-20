namespace AudioCapture.Models;

/// <summary>
/// The kind of capture error, matching Swift CaptureError variants.
/// </summary>
public enum CaptureErrorKind
{
    PermissionDenied,
    DeviceNotAvailable,
    ConfigurationFailed,
    EncodingFailed,
    EncryptionFailed,
    StorageError,
    Timeout,
    Unknown,
}

/// <summary>
/// Exception type for audio capture errors. Mirrors Swift CaptureError.
/// </summary>
public class CaptureException : Exception
{
    public CaptureErrorKind ErrorKind { get; }

    public CaptureException(CaptureErrorKind kind, string message, Exception? inner = null)
        : base(message, inner)
    {
        ErrorKind = kind;
    }

    public static CaptureException PermissionDenied(string message = "Microphone permission denied") =>
        new(CaptureErrorKind.PermissionDenied, message);

    public static CaptureException DeviceNotAvailable(string message = "Audio device not available") =>
        new(CaptureErrorKind.DeviceNotAvailable, message);

    public static CaptureException ConfigurationFailed(string message) =>
        new(CaptureErrorKind.ConfigurationFailed, message);

    public static CaptureException EncodingFailed(string message) =>
        new(CaptureErrorKind.EncodingFailed, message);

    public static CaptureException EncryptionFailed(string message) =>
        new(CaptureErrorKind.EncryptionFailed, message);

    public static CaptureException StorageError(string message) =>
        new(CaptureErrorKind.StorageError, message);

    public static CaptureException TimeoutError(string message = "Capture timed out") =>
        new(CaptureErrorKind.Timeout, message);

    public static CaptureException Unknown(string message) =>
        new(CaptureErrorKind.Unknown, message);
}
