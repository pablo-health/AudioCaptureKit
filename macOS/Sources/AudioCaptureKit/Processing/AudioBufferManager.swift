import AVFoundation
import Foundation
import os

/// Thread-safe ring buffer for managing audio sample data.
///
/// `AudioBufferManager` uses an actor to ensure safe concurrent access
/// to the underlying audio buffer. It supports writing from capture callbacks
/// and reading for processing/encoding, handling overflow gracefully by
/// dropping the oldest samples.
public actor AudioBufferManager {
    private var buffer: [Float]
    private var writeIndex = 0
    private var readIndex = 0
    private var availableSamples = 0
    private let capacity: Int

    private let logger = Logger(
        subsystem: "com.audiocapturekit",
        category: "AudioBufferManager"
    )

    /// Creates a new audio buffer manager with the specified capacity.
    /// - Parameter capacity: Maximum number of float samples the buffer can hold.
    public init(capacity: Int) {
        self.capacity = capacity
        buffer = [Float](repeating: 0, count: capacity)
    }

    /// Writes audio samples into the ring buffer.
    ///
    /// If the buffer is full, the oldest samples are overwritten and a warning is logged.
    /// - Parameter samples: The audio samples to write.
    public func write(_ samples: [Float]) {
        let count = samples.count
        if count > capacity {
            // swiftformat:disable:next redundantSelf
            logger.warning("Write size \(count) exceeds buffer capacity \(self.capacity), truncating")
            let truncated = Array(samples.suffix(capacity))
            writeInternal(truncated)
            return
        }

        let overflow = (availableSamples + count) - capacity
        if overflow > 0 {
            logger.warning("Buffer overflow: dropping \(overflow) oldest samples")
            readIndex = (readIndex + overflow) % capacity
            availableSamples -= overflow
        }

        writeInternal(samples)
    }

    private func writeInternal(_ samples: [Float]) {
        for sample in samples {
            buffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
        availableSamples += samples.count
    }

    /// Reads and removes up to the specified number of samples from the buffer.
    /// - Parameter count: The maximum number of samples to read.
    /// - Returns: An array of samples, which may be shorter than `count` if fewer are available.
    public func read(count: Int) -> [Float] {
        let samplesToRead = min(count, availableSamples)
        guard samplesToRead > 0 else { return [] }

        var result = [Float](repeating: 0, count: samplesToRead)
        for i in 0 ..< samplesToRead {
            result[i] = buffer[(readIndex + i) % capacity]
        }
        readIndex = (readIndex + samplesToRead) % capacity
        availableSamples -= samplesToRead
        return result
    }

    /// The number of samples currently available for reading.
    public var count: Int {
        availableSamples
    }

    /// Whether the buffer is empty.
    public var isEmpty: Bool {
        availableSamples == 0
    }

    /// Removes all samples from the buffer.
    public func reset() {
        writeIndex = 0
        readIndex = 0
        availableSamples = 0
    }
}
