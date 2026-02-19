import Foundation

/// Delegate protocol for receiving capture session events.
///
/// All delegate methods are called on an unspecified queue.
/// Implementations should dispatch to the main actor if UI updates are needed.
public protocol AudioCaptureDelegate: AnyObject, Sendable {
    /// Called when the capture session state changes.
    /// - Parameters:
    ///   - session: The capture session that changed state.
    ///   - state: The new state.
    func captureSession(_ session: any AudioCaptureSession, didChangeState state: CaptureState)

    /// Called periodically with updated audio level metering.
    /// - Parameters:
    ///   - session: The capture session providing levels.
    ///   - levels: The current audio levels.
    func captureSession(_ session: any AudioCaptureSession, didUpdateLevels levels: AudioLevels)

    /// Called when the capture session encounters a non-fatal error.
    /// - Parameters:
    ///   - session: The capture session that encountered the error.
    ///   - error: The error that occurred.
    func captureSession(_ session: any AudioCaptureSession, didEncounterError error: CaptureError)

    /// Called when the capture session finishes recording.
    /// - Parameters:
    ///   - session: The capture session that finished.
    ///   - result: The recording result containing file URL, duration, and metadata.
    func captureSession(_ session: any AudioCaptureSession, didFinishCapture result: RecordingResult)
}
