import AVFoundation
import Foundation

/// Callback type for receiving audio buffer data from a capture provider.
public typealias AudioBufferCallback = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

/// Protocol for individual audio capture sources.
///
/// Each implementation captures audio from a single source
/// (e.g., microphone via AVFoundation, system audio via Core Audio Taps).
public protocol AudioCaptureProvider: Sendable {
    /// Whether this capture provider is available on the current system.
    var isAvailable: Bool { get }

    /// Starts capturing audio and delivers buffers via the callback.
    /// - Parameter callback: Called for each captured audio buffer.
    /// - Throws: ``CaptureError`` if the capture cannot be started.
    func start(bufferCallback: @escaping AudioBufferCallback) async throws

    /// Stops capturing audio.
    func stop() async
}
