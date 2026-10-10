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

    /// <summary>
    /// The system-audio endpoint's own mix-format rate, or 0 when system capture
    /// was off. Unlike the mic, this rate is the device's choice, not ours — and a
    /// sidecar stamped with the configured rate while carrying this one plays at
    /// the wrong speed, so it is worth recording what the endpoint actually gave us.
    /// </summary>
    public int SystemSourceSampleRate { get; init; }

    /// <summary>The system-audio endpoint's own channel count, or 0 when system capture was off.</summary>
    public int SystemSourceChannels { get; init; }

    /// <summary>
    /// Whether the system-audio endpoint's format had to be reconciled to the
    /// configured shape. False means it already matched (or system capture was off).
    /// </summary>
    public bool SystemNormalized { get; init; }

    /// <summary>
    /// Samples (mic + system) buffered awaiting a mix cycle right now. Unlike
    /// <see cref="PeakBufferedSamples"/> this recovers after a transient stall, so
    /// sampling it over time separates a scheduling hiccup from a consumer that never
    /// catches up.
    /// </summary>
    public int BufferedSamples { get; init; }

    /// <summary>The mic source's delivered format rate, or 0 when mic capture was off.</summary>
    public int MicSampleRate { get; init; }

    /// <summary>The mic source's channel count, or 0 when mic capture was off.</summary>
    public int MicChannels { get; init; }

    /// <summary>The mic source's bits per sample, or 0 when mic capture was off.</summary>
    public int MicBitsPerSample { get; init; }

    /// <summary>The mic source's sample encoding (e.g. "Pcm"), or null when mic capture was off.</summary>
    public string? MicEncoding { get; init; }

    /// <summary>
    /// Mic frames actually delivered per second of (unpaused) capture time, or 0 before
    /// a second has elapsed. A declared 48 kHz stream that measures far off this is a
    /// device delivering at another rate — the case a Bluetooth hands-free link produces.
    /// </summary>
    public double MicMeasuredSampleRate { get; init; }

    /// <summary>
    /// The rate both sidecars are written at: the configured rate. System audio is
    /// resampled to it at capture regardless of the output device's mix format.
    /// </summary>
    public int SidecarSampleRate { get; init; }

    /// <summary>
    /// Silent frames inserted on the system channel because the loopback delivered
    /// nothing (WASAPI loopback goes quiet while nothing renders) or was between
    /// devices. Keeps the system sidecar on the same timeline as the mic.
    /// </summary>
    public long SystemPaddedFrames { get; init; }

    /// <summary>
    /// Late system frames dropped because silence had already been padded in their
    /// place. Never exceeds <see cref="SystemPaddedFrames"/>.
    /// </summary>
    public long SystemTrimmedFrames { get; init; }

    /// <summary>Times system-audio capture was re-opened on a (possibly new) output device.</summary>
    public int SystemSourceSwitches { get; init; }

    /// <summary>Times the system-audio source stopped with an error.</summary>
    public int SystemSourceErrors { get; init; }

    /// <summary>The output endpoint id loopback is capturing, or null for an injected source / none.</summary>
    public string? SystemDeviceId { get; init; }
}
