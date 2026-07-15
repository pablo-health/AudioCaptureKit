import AVFoundation
import Darwin
import Foundation

// Numeric test support for ``SignalGeneratorSoakTests``: reading a finalized
// WAV back into per-channel Float samples, detecting the deterministic
// marker bursts a ``SignalGeneratorCaptureSource`` writes into it (via a
// Goertzel single-frequency detector), and reading process RSS. Split out of
// the test file itself purely to stay under the project's file-length limit
// — these are pure functions with no dependency on the test suite's state.

private struct TestFailure: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}

struct WAVChannels {
    let left: [Float]
    let right: [Float]
    let sampleRate: Double
}

/// Reads a finalized WAV file into per-channel Float samples via
/// `AVAudioFile`. Throwing here (rather than reading garbage) is itself part
/// of the "clean finalize" proof: a truncated or corrupt header fails the read.
func readWAVChannels(_ url: URL) throws -> WAVChannels {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw TestFailure("cannot allocate WAV read buffer")
    }
    try file.read(into: buffer)
    guard let channelData = buffer.floatChannelData else {
        throw TestFailure("finalized WAV has no channel data")
    }
    let frames = Int(buffer.frameLength)
    let left = Array(UnsafeBufferPointer(start: channelData[0], count: frames))
    let right = Int(format.channelCount) > 1
        ? Array(UnsafeBufferPointer(start: channelData[1], count: frames))
        : []
    return WAVChannels(left: left, right: right, sampleRate: file.fileFormat.sampleRate)
}

// MARK: - Marker detection (Goertzel)

/// Scans `channel` for bursts at `frequency`, returning each burst's onset
/// time in seconds. Uses overlapping Goertzel windows: short enough (10ms) to
/// localize onset well inside the ±20ms tolerance the soak checks against,
/// long enough (480 samples @ 48kHz ≈ 100Hz resolution) that the 1kHz spacing
/// between the four marker/base tones doesn't leak across bins.
func detectMarkerOnsets(
    in channel: [Float],
    sampleRate: Double,
    frequency: Double,
    windowSeconds: Double = 0.01,
    hopSeconds: Double = 0.002
) -> [TimeInterval] {
    let windowSize = max(1, Int(sampleRate * windowSeconds))
    let hopSize = max(1, Int(sampleRate * hopSeconds))
    guard channel.count >= windowSize else { return [] }

    // Hysteresis (two thresholds, not one) avoids double-counting a single
    // burst if its measured magnitude dips near the boundary mid-burst.
    let onThreshold = 0.05
    let offThreshold = 0.02

    var onsets: [TimeInterval] = []
    var isInBurst = false
    var offset = 0
    while offset + windowSize <= channel.count {
        let magnitude = goertzelMagnitude(
            channel[offset ..< (offset + windowSize)], frequency: frequency, sampleRate: sampleRate
        )
        if !isInBurst, magnitude >= onThreshold {
            onsets.append(Double(offset) / sampleRate)
            isInBurst = true
        } else if isInBurst, magnitude < offThreshold {
            isInBurst = false
        }
        offset += hopSize
    }
    return onsets
}

/// Single-frequency Goertzel magnitude for a window of samples, normalized by
/// window length so it's comparable to a sine amplitude (a full-scale
/// on-frequency tone of amplitude `A` yields magnitude ≈ `A / 2`).
func goertzelMagnitude(_ window: ArraySlice<Float>, frequency: Double, sampleRate: Double) -> Double {
    let sampleCount = window.count
    guard sampleCount > 0 else { return 0 }
    let binIndex = (0.5 + Double(sampleCount) * frequency / sampleRate).rounded(.down)
    let omega = 2.0 * .pi * binIndex / Double(sampleCount)
    let coeff = 2.0 * cos(omega)
    var s1 = 0.0
    var s2 = 0.0
    for sample in window {
        let s0 = Double(sample) + coeff * s1 - s2
        s2 = s1
        s1 = s0
    }
    let real = s1 - s2 * cos(omega)
    let imag = s2 * sin(omega)
    return (real * real + imag * imag).squareRoot() / Double(sampleCount)
}

// MARK: - Process memory (RSS)

/// Current resident set size, in bytes, via `task_info`. Returns 0 (never
/// negative/garbage) if the query fails, which would only understate a leak
/// rather than falsely flag one.
func currentResidentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPointer, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return info.resident_size
}
