namespace AudioCapture.Models;

/// <summary>
/// The kind of state the capture session is in.
/// </summary>
public enum CaptureStateKind
{
    Idle,
    Configuring,
    Ready,
    Capturing,
    Paused,
    Stopping,
    Completed,
    Failed,
}

/// <summary>
/// Represents the current state of a capture session, including associated data.
/// Mirrors Swift CaptureState enum with associated values.
/// </summary>
public sealed record CaptureState
{
    public CaptureStateKind Kind { get; }
    public TimeSpan Duration { get; }
    public RecordingResult? Result { get; }
    public CaptureException? Error { get; }

    private CaptureState(CaptureStateKind kind, TimeSpan duration = default,
        RecordingResult? result = null, CaptureException? error = null)
    {
        Kind = kind;
        Duration = duration;
        Result = result;
        Error = error;
    }

    public static CaptureState Idle => new(CaptureStateKind.Idle);
    public static CaptureState Configuring => new(CaptureStateKind.Configuring);
    public static CaptureState Ready => new(CaptureStateKind.Ready);
    public static CaptureState Capturing(TimeSpan duration) => new(CaptureStateKind.Capturing, duration);
    public static CaptureState Paused(TimeSpan duration) => new(CaptureStateKind.Paused, duration);
    public static CaptureState Stopping => new(CaptureStateKind.Stopping);
    public static CaptureState Completed(RecordingResult result) => new(CaptureStateKind.Completed, result: result);
    public static CaptureState Failed(CaptureException error) => new(CaptureStateKind.Failed, error: error);

    /// <summary>
    /// Returns whether transitioning to the given target state is valid.
    /// </summary>
    public bool CanTransitionTo(CaptureStateKind target) => (Kind, target) switch
    {
        (CaptureStateKind.Idle, CaptureStateKind.Configuring) => true,
        (CaptureStateKind.Configuring, CaptureStateKind.Ready) => true,
        (CaptureStateKind.Configuring, CaptureStateKind.Failed) => true,
        (CaptureStateKind.Ready, CaptureStateKind.Capturing) => true,
        (CaptureStateKind.Ready, CaptureStateKind.Failed) => true,
        (CaptureStateKind.Capturing, CaptureStateKind.Paused) => true,
        (CaptureStateKind.Capturing, CaptureStateKind.Stopping) => true,
        (CaptureStateKind.Capturing, CaptureStateKind.Failed) => true,
        (CaptureStateKind.Paused, CaptureStateKind.Capturing) => true,
        (CaptureStateKind.Paused, CaptureStateKind.Stopping) => true,
        (CaptureStateKind.Paused, CaptureStateKind.Failed) => true,
        (CaptureStateKind.Stopping, CaptureStateKind.Completed) => true,
        (CaptureStateKind.Stopping, CaptureStateKind.Failed) => true,
        // Allow reset from terminal states
        (CaptureStateKind.Completed, CaptureStateKind.Idle) => true,
        (CaptureStateKind.Failed, CaptureStateKind.Idle) => true,
        _ => false,
    };
}
