import Foundation

/// Represents the current state of a capture session.
public enum CaptureState: Sendable {
    /// No capture is in progress or configured.
    case idle

    /// The capture session is being configured.
    case configuring

    /// The capture session is configured and ready to start.
    case ready

    /// Audio is being actively captured.
    case capturing(duration: TimeInterval)

    /// Capture is paused.
    case paused(duration: TimeInterval)

    /// The capture session is being stopped and finalized.
    case stopping

    /// The capture session completed successfully.
    case completed(RecordingResult)

    /// The capture session failed with an error.
    case failed(CaptureError)
}

extension CaptureState: Equatable {
    public static func == (lhs: CaptureState, rhs: CaptureState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.configuring, .configuring),
             (.ready, .ready),
             (.stopping, .stopping):
            true
        case let (.capturing(lhsDuration), .capturing(rhsDuration)):
            lhsDuration == rhsDuration
        case let (.paused(lhsDuration), .paused(rhsDuration)):
            lhsDuration == rhsDuration
        case let (.completed(lhsResult), .completed(rhsResult)):
            lhsResult == rhsResult
        case let (.failed(lhsError), .failed(rhsError)):
            lhsError == rhsError
        default:
            false
        }
    }
}
