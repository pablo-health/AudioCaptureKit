import Foundation

/// Protocol defining the interface for a media capture session.
///
/// `AudioCaptureSession` manages the complete lifecycle of an audio recording,
/// from configuration through capture to finalization. It coordinates multiple
/// audio sources, handles the state machine, and produces encrypted output files.
///
/// The canonical implementation is ``CompositeCaptureSession``, which combines
/// microphone and system audio capture into a stereo recording.
public protocol AudioCaptureSession: AnyObject, Sendable {
    /// The current state of the capture session.
    var state: CaptureState { get }

    /// Delegate for receiving capture session events.
    var delegate: (any AudioCaptureDelegate)? { get set }

    /// The current configuration of the capture session.
    var configuration: CaptureConfiguration { get }

    /// The most recent audio level readings.
    var currentLevels: AudioLevels { get }

    /// Returns a list of available audio sources on the system.
    /// - Returns: An array of available audio input and output sources.
    /// - Throws: ``CaptureError`` if sources cannot be enumerated.
    func availableAudioSources() async throws -> [AudioSource]

    /// Configures the capture session with the specified parameters.
    /// - Parameter configuration: The desired capture configuration.
    /// - Throws: ``CaptureError/configurationFailed(_:)`` if configuration is invalid.
    func configure(_ configuration: CaptureConfiguration) throws

    /// Starts capturing audio.
    /// - Throws: ``CaptureError`` if capture cannot be started.
    func startCapture() async throws

    /// Pauses an active capture session.
    /// - Throws: ``CaptureError`` if the session is not in a capturable state.
    func pauseCapture() throws

    /// Resumes a paused capture session.
    /// - Throws: ``CaptureError`` if the session is not paused.
    func resumeCapture() throws

    /// Stops capturing and finalizes the recording.
    /// - Returns: The result of the recording including file URL and metadata.
    /// - Throws: ``CaptureError`` if the recording cannot be finalized.
    func stopCapture() async throws -> RecordingResult
}
