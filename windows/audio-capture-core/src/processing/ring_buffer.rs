/// Thread-safe circular ring buffer for audio samples.
///
/// Ports Swift's `AudioBufferManager` actor. In Rust, wrap in
/// `Arc<Mutex<RingBuffer>>` or `Arc<parking_lot::Mutex<RingBuffer>>`
/// for cross-thread access.
///
/// Overflow behavior: drops oldest samples (same as Swift version).
#[derive(Debug)]
pub struct RingBuffer {
    buffer: Vec<f32>,
    write_index: usize,
    read_index: usize,
    available: usize,
    capacity: usize,
}

impl RingBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            buffer: vec![0.0; capacity],
            write_index: 0,
            read_index: 0,
            available: 0,
            capacity,
        }
    }

    /// Write samples into the ring buffer.
    ///
    /// If the buffer overflows, the oldest samples are dropped.
    /// If `samples` is larger than capacity, only the last `capacity` samples are kept.
    pub fn write(&mut self, samples: &[f32]) {
        if samples.is_empty() {
            return;
        }

        // If more data than capacity, only keep the tail
        let samples = if samples.len() > self.capacity {
            &samples[samples.len() - self.capacity..]
        } else {
            samples
        };

        // Drop oldest if we'd overflow
        let overflow = (self.available + samples.len()).saturating_sub(self.capacity);
        if overflow > 0 {
            self.read_index = (self.read_index + overflow) % self.capacity;
            self.available -= overflow;
        }

        // Write samples into circular buffer
        for &sample in samples {
            self.buffer[self.write_index] = sample;
            self.write_index = (self.write_index + 1) % self.capacity;
        }
        self.available += samples.len();
    }

    /// Read and remove up to `count` samples from the buffer.
    ///
    /// Returns fewer samples if fewer are available.
    pub fn read(&mut self, count: usize) -> Vec<f32> {
        let to_read = count.min(self.available);
        if to_read == 0 {
            return Vec::new();
        }

        let mut result = Vec::with_capacity(to_read);
        for i in 0..to_read {
            result.push(self.buffer[(self.read_index + i) % self.capacity]);
        }
        self.read_index = (self.read_index + to_read) % self.capacity;
        self.available -= to_read;
        result
    }

    /// Number of samples currently available for reading.
    pub fn count(&self) -> usize {
        self.available
    }

    /// Whether the buffer is empty.
    pub fn is_empty(&self) -> bool {
        self.available == 0
    }

    /// Reset the buffer to empty state.
    pub fn reset(&mut self) {
        self.write_index = 0;
        self.read_index = 0;
        self.available = 0;
    }

    /// The total capacity of the buffer.
    pub fn capacity(&self) -> usize {
        self.capacity
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basic_write_read() {
        let mut buf = RingBuffer::new(10);
        buf.write(&[1.0, 2.0, 3.0]);

        assert_eq!(buf.count(), 3);
        assert_eq!(buf.read(3), vec![1.0, 2.0, 3.0]);
        assert!(buf.is_empty());
    }

    #[test]
    fn read_partial() {
        let mut buf = RingBuffer::new(10);
        buf.write(&[1.0, 2.0, 3.0, 4.0, 5.0]);

        let first = buf.read(3);
        assert_eq!(first, vec![1.0, 2.0, 3.0]);
        assert_eq!(buf.count(), 2);

        let rest = buf.read(10); // request more than available
        assert_eq!(rest, vec![4.0, 5.0]);
        assert!(buf.is_empty());
    }

    #[test]
    fn overflow_drops_oldest() {
        let mut buf = RingBuffer::new(4);
        buf.write(&[1.0, 2.0, 3.0, 4.0]);
        buf.write(&[5.0, 6.0]); // overflow: drops 1.0, 2.0

        assert_eq!(buf.count(), 4);
        assert_eq!(buf.read(4), vec![3.0, 4.0, 5.0, 6.0]);
    }

    #[test]
    fn write_larger_than_capacity() {
        let mut buf = RingBuffer::new(3);
        buf.write(&[1.0, 2.0, 3.0, 4.0, 5.0]); // only last 3 kept

        assert_eq!(buf.count(), 3);
        assert_eq!(buf.read(3), vec![3.0, 4.0, 5.0]);
    }

    #[test]
    fn wraparound() {
        let mut buf = RingBuffer::new(4);

        buf.write(&[1.0, 2.0, 3.0]);
        buf.read(2); // discard 1.0, 2.0; read_index = 2

        buf.write(&[4.0, 5.0, 6.0]); // wraps around

        assert_eq!(buf.count(), 4);
        assert_eq!(buf.read(4), vec![3.0, 4.0, 5.0, 6.0]);
    }

    #[test]
    fn reset_clears_buffer() {
        let mut buf = RingBuffer::new(10);
        buf.write(&[1.0, 2.0, 3.0]);
        buf.reset();

        assert!(buf.is_empty());
        assert_eq!(buf.count(), 0);
        assert!(buf.read(10).is_empty());
    }

    #[test]
    fn empty_operations() {
        let mut buf = RingBuffer::new(10);

        assert!(buf.is_empty());
        assert!(buf.read(5).is_empty());

        buf.write(&[]);
        assert!(buf.is_empty());
    }
}
