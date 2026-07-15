namespace AudioCapture.Models;

/// <summary>
/// Counters describing what actually flowed through a capture session.
///
/// A capture that produces a well-formed but silent recording looks identical to
/// a healthy one from the outside — same state transitions, same file, same
/// duration. These counters separate the failure modes: no
/// <see cref="MicChunks"/> means the source never delivered, while chunks but no
/// <see cref="BytesWritten"/> means the mix/write path dropped them.
/// </summary>
public sealed record CaptureDiagnostics
{
    /// <summary>Times the mix timer ran and had buffered audio to write.</summary>
    public long MixCycles { get; init; }

    /// <summary>Bytes of mixed PCM handed to the WAV writer.</summary>
    public long BytesWritten { get; init; }

    /// <summary>Buffers received from the mic source.</summary>
    public long MicChunks { get; init; }

    /// <summary>Bytes received from the mic source, as delivered (pre-conversion).</summary>
    public long MicBytes { get; init; }

    /// <summary>Buffers received from the system-audio source.</summary>
    public long SystemChunks { get; init; }

    /// <summary>Bytes received from the system-audio source, as delivered (pre-conversion).</summary>
    public long SystemBytes { get; init; }

    /// <summary>Mix/write cycles that threw. Non-zero means audio was lost.</summary>
    public long MixErrors { get; init; }

    /// <summary>
    /// High-water mark of samples buffered awaiting a mix cycle. Climbing without
    /// bound points at a stalled mix timer.
    /// </summary>
    public int PeakBufferedSamples { get; init; }
}
