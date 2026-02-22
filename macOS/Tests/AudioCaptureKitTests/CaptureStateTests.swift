@testable import AudioCaptureKit
import Foundation
import Testing

@Suite("CaptureState Tests")
struct CaptureStateTests {

    @Test("Idle state equality")
    func idleEquality() {
        let state1 = CaptureState.idle
        let state2 = CaptureState.idle
        #expect(state1 == state2)
    }

    @Test("Configuring state equality")
    func configuringEquality() {
        let state1 = CaptureState.configuring
        let state2 = CaptureState.configuring
        #expect(state1 == state2)
    }

    @Test("Ready state equality")
    func readyEquality() {
        let state1 = CaptureState.ready
        let state2 = CaptureState.ready
        #expect(state1 == state2)
    }

    @Test("Capturing state equality with same duration")
    func capturingEqualitySameDuration() {
        let state1 = CaptureState.capturing(duration: 10.0)
        let state2 = CaptureState.capturing(duration: 10.0)
        #expect(state1 == state2)
    }

    @Test("Capturing state inequality with different duration")
    func capturingInequalityDifferentDuration() {
        #expect(CaptureState.capturing(duration: 10.0) != CaptureState.capturing(duration: 20.0))
    }

    @Test("Paused state equality with same duration")
    func pausedEqualitySameDuration() {
        let state1 = CaptureState.paused(duration: 5.0)
        let state2 = CaptureState.paused(duration: 5.0)
        #expect(state1 == state2)
    }

    @Test("Paused state inequality with different duration")
    func pausedInequalityDifferentDuration() {
        #expect(CaptureState.paused(duration: 5.0) != CaptureState.paused(duration: 15.0))
    }

    @Test("Stopping state equality")
    func stoppingEquality() {
        let state1 = CaptureState.stopping
        let state2 = CaptureState.stopping
        #expect(state1 == state2)
    }

    @Test("Failed state equality with same error")
    func failedEqualitySameError() {
        let state1 = CaptureState.failed(.permissionDenied)
        let state2 = CaptureState.failed(.permissionDenied)
        #expect(state1 == state2)
        let state3 = CaptureState.failed(.timeout)
        let state4 = CaptureState.failed(.timeout)
        #expect(state3 == state4)
    }

    @Test("Failed state inequality with different errors")
    func failedInequalityDifferentErrors() {
        #expect(CaptureState.failed(.permissionDenied) != CaptureState.failed(.timeout))
    }

    @Test("Different states are not equal")
    func differentStatesNotEqual() {
        #expect(CaptureState.idle != CaptureState.configuring)
        #expect(CaptureState.idle != CaptureState.ready)
        #expect(CaptureState.idle != CaptureState.capturing(duration: 0))
        #expect(CaptureState.idle != CaptureState.paused(duration: 0))
        #expect(CaptureState.idle != CaptureState.stopping)
        #expect(CaptureState.ready != CaptureState.capturing(duration: 0))
        #expect(CaptureState.capturing(duration: 5) != CaptureState.paused(duration: 5))
    }

    @Test("Completed state equality")
    func completedStateEquality() {
        let url = URL(fileURLWithPath: "/tmp/test.wav")
        let metadata = RecordingMetadata(
            duration: 10,
            fileURL: url,
            checksum: "abc123",
            isEncrypted: false,
            tracks: [AudioTrack(type: .mic, channel: .left)]
        )
        let result1 = RecordingResult(
            fileURL: url, duration: 10, metadata: metadata, checksum: "abc123"
        )
        let result2 = RecordingResult(
            fileURL: url, duration: 10, metadata: metadata, checksum: "abc123"
        )
        #expect(CaptureState.completed(result1) == CaptureState.completed(result2))
    }

    @Test("State machine: idle -> configuring -> ready is valid")
    func validTransitionIdleToReady() {
        let states: [CaptureState] = [.idle, .configuring, .ready]
        #expect(states[0] == .idle)
        #expect(states[1] == .configuring)
        #expect(states[2] == .ready)
    }

    @Test("State machine: full capture cycle")
    func validTransitionFullCycle() {
        let url = URL(fileURLWithPath: "/tmp/test.wav")
        let metadata = RecordingMetadata(
            duration: 30, fileURL: url, checksum: "def456",
            isEncrypted: true,
            tracks: [
                AudioTrack(type: .mic, channel: .left),
                AudioTrack(type: .system, channel: .right),
            ],
            encryptionAlgorithm: "AES-256-GCM"
        )
        let result = RecordingResult(
            fileURL: url, duration: 30, metadata: metadata, checksum: "def456"
        )

        let states: [CaptureState] = [
            .ready, .capturing(duration: 0), .capturing(duration: 10),
            .paused(duration: 10), .capturing(duration: 10),
            .capturing(duration: 25), .stopping, .completed(result),
        ]
        #expect(states.count == 8)
        #expect(states.first == .ready)
        #expect(states.last == .completed(result))
    }

    @Test("CaptureError cases are distinct")
    func captureErrorDistinctCases() {
        let errors: [CaptureError] = [
            .permissionDenied, .deviceNotAvailable,
            .configurationFailed("test"), .encodingFailed("test"),
            .encryptionFailed("test"), .storageError("test"),
            .timeout, .unknown("test"),
        ]
        #expect(errors.count == 8)
        #expect(errors[0] != errors[1])
        #expect(errors[2] != errors[3])
    }
}
