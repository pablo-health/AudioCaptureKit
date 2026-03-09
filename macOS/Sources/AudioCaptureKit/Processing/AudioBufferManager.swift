import Foundation
import os

/// Thread-safe ring buffer for managing audio sample data.
///
/// Uses `UnfairLock` for synchronous mutual exclusion, avoiding the
/// Swift concurrency scheduling overhead of an actor. This is critical
/// for the audio hot path where callbacks fire at 48 kHz and any
/// scheduling delay can cause buffer overflow.
public final class AudioBufferManager: @unchecked Sendable {
    private struct State {
        var buffer: [Float]
        var writeIndex = 0
        var readIndex = 0
        var availableSamples = 0
        let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
            self.buffer = [Float](repeating: 0, count: capacity)
        }
    }

    private let state: UnfairLock<State>

    private let logger = Logger(
        subsystem: "com.audiocapturekit",
        category: "AudioBufferManager"
    )

    /// Creates a new audio buffer manager with the specified capacity.
    /// - Parameter capacity: Maximum number of float samples the buffer can hold.
    public init(capacity: Int) {
        self.state = UnfairLock(State(capacity: capacity))
    }

    /// Writes audio samples into the ring buffer.
    ///
    /// If the buffer is full, the oldest samples are overwritten and a warning is logged.
    /// - Parameter samples: The audio samples to write.
    public func write(_ samples: [Float]) {
        let count = samples.count
        state.withLock { s in
            let capacity = s.capacity

            let samplesToWrite: ArraySlice<Float>
            if count > capacity {
                logger.warning("Write size \(count) exceeds buffer capacity \(capacity), truncating")
                samplesToWrite = samples.suffix(capacity)
            } else {
                samplesToWrite = samples[...]
            }

            let overflow = (s.availableSamples + samplesToWrite.count) - capacity
            if overflow > 0 {
                logger.warning("Buffer overflow: dropping \(overflow) oldest samples")
                s.readIndex = (s.readIndex + overflow) % capacity
                s.availableSamples -= overflow
            }

            for sample in samplesToWrite {
                s.buffer[s.writeIndex] = sample
                s.writeIndex = (s.writeIndex + 1) % capacity
            }
            s.availableSamples += samplesToWrite.count
        }
    }

    /// Reads and removes up to the specified number of samples from the buffer.
    /// - Parameter count: The maximum number of samples to read.
    /// - Returns: An array of samples, which may be shorter than `count` if fewer are available.
    public func read(count: Int) -> [Float] {
        state.withLock { s in
            let samplesToRead = min(count, s.availableSamples)
            guard samplesToRead > 0 else { return [] }

            var result = [Float](repeating: 0, count: samplesToRead)
            for i in 0 ..< samplesToRead {
                result[i] = s.buffer[(s.readIndex + i) % s.capacity]
            }
            s.readIndex = (s.readIndex + samplesToRead) % s.capacity
            s.availableSamples -= samplesToRead
            return result
        }
    }

    /// The number of samples currently available for reading.
    public var count: Int {
        state.withLock { $0.availableSamples }
    }

    /// Whether the buffer is empty.
    public var isEmpty: Bool {
        state.withLock { $0.availableSamples == 0 }
    }

    /// Removes all samples from the buffer.
    public func reset() {
        state.withLock { s in
            s.writeIndex = 0
            s.readIndex = 0
            s.availableSamples = 0
        }
    }
}
