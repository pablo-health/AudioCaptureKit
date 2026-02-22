import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation
import AudioCaptureKit
import os

/// Manages the recording lifecycle using CompositeCaptureSession.
@MainActor
@Observable
final class RecordingViewModel {
    // MARK: - Published State

    var recordingState: RecordingUIState = .idle
    var micLevel: Float = 0
    var systemLevel: Float = 0
    var peakMicLevel: Float = 0
    var peakSystemLevel: Float = 0
    var duration: TimeInterval = 0
    var recordings: [LocalRecording] = []
    var availableMics: [AudioSource] = []
    var selectedMicID: String? {
        didSet { checkBluetoothRoutingConflict() }
    }
    var encryptionEnabled: Bool = true
    var errorMessage: String?
    var showError: Bool = false
    var playingRecordingID: UUID?
    var systemAudioActive: Bool = false
    var bluetoothRoutingConflict: Bool = false
    var bluetoothRecommendation: String?
    var systemAudioPermitted: Bool = CGPreflightScreenCaptureAccess()

    // MARK: - Debug / Diagnostics

    var debugEnableMic: Bool = true
    var debugEnableSystem: Bool = true
    var debugDiagnostics: CaptureSessionDiagnostics = .init()

    // MARK: - Private

    private var session: CompositeCaptureSession?
    private var audioPlayer: AVAudioPlayer?
    private let playerDelegate = AudioPlayerDelegateAdapter()
    private let logger = Logger(subsystem: "com.macos-sample", category: "RecordingViewModel")
    private let delegateAdapter = CaptureDelegateAdapter()
    private var deviceChangeListenerInstalled = false
    private var systemAudioAvailableAtStart = false

    // MARK: - Recording Controls

    func loadAudioSources() async {
        systemAudioPermitted = CGPreflightScreenCaptureAccess()
        await refreshAudioSources()
        installDeviceChangeListener()
    }

    /// Queries available audio sources and updates the mic list.
    private func refreshAudioSources() async {
        let tempSession = CompositeCaptureSession(
            configuration: CaptureConfiguration(outputDirectory: recordingsDirectory)
        )
        do {
            let sources = try await tempSession.availableAudioSources()
            let previousSelection = selectedMicID
            availableMics = sources.filter { $0.type == .mic }
            let systemSources = sources.filter { $0.type == .system }
            systemAudioAvailableAtStart = !systemSources.isEmpty

            // Preserve selection if the device is still available, otherwise pick default
            if let previousSelection, availableMics.contains(where: { $0.id == previousSelection }) {
                selectedMicID = previousSelection
            } else {
                selectedMicID = availableMics.first(where: { $0.isDefault })?.id
                    ?? availableMics.first?.id
            }
            logger.info("Audio sources refreshed: \(self.availableMics.count) mic(s), system audio available: \(self.systemAudioAvailableAtStart)")
            checkBluetoothRoutingConflict()
        } catch {
            logger.error("Failed to load audio sources: \(error.localizedDescription)")
            showErrorAlert("Failed to load audio sources: \(error.localizedDescription)")
        }
    }

    /// Listens for Core Audio device additions/removals and refreshes the mic list.
    private func installDeviceChangeListener() {
        guard !deviceChangeListenerInstalled else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // The listener block fires on an arbitrary CoreAudio queue.
        // In Swift 6, closures inherit the actor isolation of the enclosing
        // context — so a bare `{ _, _ in }` here would be @MainActor-isolated
        // and crash with _dispatch_assert_queue_fail when CoreAudio calls it.
        // We break that by declaring the block as an explicit @Sendable variable.
        let weakSelf = WeakSendableBox(self)

        let listenerBlock: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in
            DispatchQueue.main.async {
                Task { @MainActor in
                    guard let viewModel = weakSelf.value else { return }
                    viewModel.logger.info("Audio device change detected, refreshing sources")

                    // Only stop recording if the selected mic actually disappeared.
                    // Device additions (e.g. aggregate device created by system audio
                    // capture) should not interrupt an active recording.
                    if viewModel.recordingState == .recording || viewModel.recordingState == .paused {
                        if let micID = viewModel.selectedMicID,
                           !viewModel.isMicStillAvailable(micID) {
                            viewModel.logger.warning("Selected mic \(micID) disconnected during recording, stopping")
                            await viewModel.stopRecording()
                            viewModel.showErrorAlert("Recording stopped: microphone was disconnected")
                        } else {
                            viewModel.logger.info("Device change during recording, but selected mic still available")
                        }
                    }

                    if viewModel.playingRecordingID != nil {
                        viewModel.logger.info("Device changed during playback, stopping playback")
                        viewModel.stopPlayback()
                    }

                    await viewModel.refreshAudioSources()
                }
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            listenerBlock
        )

        if status == noErr {
            deviceChangeListenerInstalled = true
            logger.info("Audio device change listener installed")
        } else {
            logger.error("Failed to install audio device change listener: \(status)")
        }
    }

    func startRecording() async {
        logger.info("Starting recording – system audio available at source check: \(self.systemAudioAvailableAtStart)")

        let encryptor: DemoEncryptor? = encryptionEnabled ? DemoEncryptor() : nil
        let config = CaptureConfiguration(
            sampleRate: 48000,
            bitDepth: 16,
            channels: 2,
            encryptor: encryptor,
            outputDirectory: recordingsDirectory,
            micDeviceID: selectedMicID,
            enableMicCapture: debugEnableMic,
            enableSystemCapture: debugEnableSystem
        )

        let captureSession = CompositeCaptureSession(configuration: config)
        self.session = captureSession

        delegateAdapter.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleStateChange(state)
            }
        }
        delegateAdapter.onLevelsUpdate = { [weak self] levels in
            Task { @MainActor in
                self?.micLevel = levels.micLevel
                self?.systemLevel = levels.systemLevel
                self?.peakMicLevel = levels.peakMicLevel
                self?.peakSystemLevel = levels.peakSystemLevel
            }
        }
        delegateAdapter.onError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.logger.error("Capture error: \(error.localizedDescription)")
                // System audio config errors are non-fatal — recording continues with mic only
                if case .configurationFailed(let msg) = error,
                   msg.contains("System audio") {
                    self.systemAudioActive = false
                    self.logger.warning("System audio not available, recording mic only")
                }
                self.showErrorAlert(error.localizedDescription)
            }
        }
        captureSession.delegate = delegateAdapter

        do {
            try captureSession.configure(config)
            try await captureSession.startCapture()
            recordingState = .recording
            systemAudioActive = systemAudioAvailableAtStart
            logger.info("Recording started – systemAudioActive: \(self.systemAudioActive)")
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
            showErrorAlert("Failed to start recording: \(error.localizedDescription)")
            recordingState = .idle
            systemAudioActive = false
        }
    }

    func pauseRecording() {
        guard let session else { return }
        do {
            try session.pauseCapture()
            recordingState = .paused
            logger.info("Recording paused")
        } catch {
            logger.error("Failed to pause: \(error.localizedDescription)")
            showErrorAlert("Failed to pause: \(error.localizedDescription)")
        }
    }

    func resumeRecording() {
        guard let session else { return }
        do {
            try session.resumeCapture()
            recordingState = .recording
            logger.info("Recording resumed")
        } catch {
            logger.error("Failed to resume: \(error.localizedDescription)")
            showErrorAlert("Failed to resume: \(error.localizedDescription)")
        }
    }

    func stopRecording() async {
        guard let session else { return }
        do {
            let result = try await session.stopCapture()
            logger.info("Recording stopped: \(result.fileURL.lastPathComponent)")

            let recording = LocalRecording(
                id: result.metadata.id,
                fileURL: result.fileURL,
                duration: result.duration,
                createdAt: Date(),
                isEncrypted: result.metadata.isEncrypted,
                checksum: result.checksum
            )
            recordings.insert(recording, at: 0)
            recordingState = .idle
            resetLevels()
        } catch {
            logger.error("Failed to stop recording: \(error.localizedDescription)")
            showErrorAlert("Failed to stop recording: \(error.localizedDescription)")
            recordingState = .idle
            resetLevels()
        }
        systemAudioActive = false
        self.session = nil
    }

    // MARK: - Test Tone

    /// Generates a 3-second test tone recording (440Hz left, 880Hz right)
    /// that bypasses all capture. Proves the file writing + playback path works.
    func generateTestTone() {
        let sampleRate: Double = 48000
        let durationSecs: Double = 3.0
        let frameCount = Int(sampleRate * durationSecs)

        // Generate stereo interleaved: 440Hz sine in left, 880Hz sine in right
        var stereo = [Float](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            let t = Float(i) / Float(sampleRate)
            stereo[i * 2] = 0.5 * sin(2.0 * .pi * 440.0 * t)     // Left: 440Hz
            stereo[i * 2 + 1] = 0.5 * sin(2.0 * .pi * 880.0 * t) // Right: 880Hz
        }

        // Convert to 16-bit PCM
        var pcmData = Data(capacity: stereo.count * 2)
        for sample in stereo {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: &int16) { pcmData.append(contentsOf: $0) }
        }

        // Write WAV file
        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: UInt32(sampleRate),
            bitDepth: 16,
            channels: 2,
            dataSize: UInt32(pcmData.count)
        )

        let fileName = "test_tone_\(UUID().uuidString).wav"
        let fileURL = recordingsDirectory.appendingPathComponent(fileName)
        do {
            var wavData = header
            wavData.append(pcmData)
            try wavData.write(to: fileURL)

            let recording = LocalRecording(
                id: UUID(),
                fileURL: fileURL,
                duration: durationSecs,
                createdAt: Date(),
                isEncrypted: false,
                checksum: "test-tone"
            )
            recordings.insert(recording, at: 0)
            logger.info("Test tone generated: \(fileName)")
        } catch {
            showErrorAlert("Failed to generate test tone: \(error.localizedDescription)")
        }
    }

    // MARK: - Playback

    func playRecording(_ recording: LocalRecording) {
        stopPlayback()

        do {
            let player: AVAudioPlayer
            if recording.isEncrypted {
                let wavData = try DemoEncryptor.decryptFile(at: recording.fileURL)
                player = try AVAudioPlayer(data: wavData)
            } else {
                player = try AVAudioPlayer(contentsOf: recording.fileURL)
            }

            playerDelegate.onFinish = { [weak self] in
                Task { @MainActor in
                    self?.playingRecordingID = nil
                    self?.audioPlayer = nil
                }
            }
            player.delegate = playerDelegate
            player.play()
            audioPlayer = player
            playingRecordingID = recording.id
        } catch {
            logger.error("Playback failed: \(error.localizedDescription)")
            showErrorAlert("Playback failed: \(error.localizedDescription)")
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingRecordingID = nil
    }

    // MARK: - Helpers

    private func handleStateChange(_ state: CaptureState) {
        logger.debug("State change: \(String(describing: state)), systemAudioActive: \(self.systemAudioActive)")
        switch state {
        case .idle:
            recordingState = .idle
            duration = 0
        case .capturing(let elapsed):
            recordingState = .recording
            duration = elapsed
            // Poll diagnostics from the session
            if let session {
                debugDiagnostics = session.diagnostics
            }
        case .paused(let elapsed):
            recordingState = .paused
            duration = elapsed
        case .stopping:
            recordingState = .idle
            // Final diagnostics snapshot
            if let session {
                debugDiagnostics = session.diagnostics
            }
        case .failed(let error):
            recordingState = .idle
            systemAudioActive = false
            showErrorAlert(error.localizedDescription)
        default:
            break
        }
    }

    private func resetLevels() {
        micLevel = 0
        systemLevel = 0
        peakMicLevel = 0
        peakSystemLevel = 0
        duration = 0
        systemAudioActive = false
    }

    private func showErrorAlert(_ message: String) {
        errorMessage = message
        showError = true
    }

    /// Checks if the selected mic is a Bluetooth device that also serves as the current output,
    /// which would force macOS into HFP mode (mono ~16kHz).
    private func checkBluetoothRoutingConflict() {
        guard let selectedMicID,
              let mic = availableMics.first(where: { $0.id == selectedMicID }),
              mic.transportType == .bluetooth || mic.transportType == .bluetoothLE
        else {
            bluetoothRoutingConflict = false
            bluetoothRecommendation = nil
            return
        }

        guard let outputUID = Self.defaultOutputDeviceUID() else {
            bluetoothRoutingConflict = false
            bluetoothRecommendation = nil
            return
        }

        // Compare the UID prefix — Bluetooth input/output devices share the same base UID
        // but may have different suffixes (e.g. ":input" / ":output"). A prefix match is
        // sufficient because macOS uses the same Bluetooth chip for both directions.
        let micBase = selectedMicID.components(separatedBy: ":").first ?? selectedMicID
        let outputBase = outputUID.components(separatedBy: ":").first ?? outputUID

        if micBase == outputBase {
            bluetoothRoutingConflict = true
            bluetoothRecommendation =
                "Using \(mic.name) as mic while it's also the audio output forces HFP mode (mono ~16 kHz). "
                + "This is fine for speech recognition, but audio quality will drop. "
                + "Switch to the built-in mic for higher quality, or continue if convenience matters more."
        } else {
            bluetoothRoutingConflict = false
            bluetoothRecommendation = nil
        }
    }

    /// Checks if a mic device UID is still present in the CoreAudio device list.
    func isMicStillAvailable(_ deviceUID: String) -> Bool {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discoverySession.devices.contains { $0.uniqueID == deviceUID }
    }

    /// Returns the UID of the current default output audio device.
    private static func defaultOutputDeviceUID() -> String? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else { return nil }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidStatus = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &uid
        )
        guard uidStatus == noErr, let uid = uid?.takeUnretainedValue() else { return nil }
        return uid as String
    }

    private var recordingsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacOSSample-Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - UI State

enum RecordingUIState: Equatable, Sendable {
    case idle
    case recording
    case paused
}

// MARK: - Delegate Adapter

/// Bridges the non-isolated AudioCaptureDelegate callbacks to MainActor closures.
private final class CaptureDelegateAdapter: AudioCaptureDelegate, @unchecked Sendable {
    var onStateChange: (@Sendable (CaptureState) -> Void)?
    var onLevelsUpdate: (@Sendable (AudioLevels) -> Void)?
    var onError: (@Sendable (CaptureError) -> Void)?
    var onFinish: (@Sendable (RecordingResult) -> Void)?

    func captureSession(
        _ session: any AudioCaptureSession,
        didChangeState state: CaptureState
    ) {
        onStateChange?(state)
    }

    func captureSession(
        _ session: any AudioCaptureSession,
        didUpdateLevels levels: AudioLevels
    ) {
        onLevelsUpdate?(levels)
    }

    func captureSession(
        _ session: any AudioCaptureSession,
        didEncounterError error: CaptureError
    ) {
        onError?(error)
    }

    func captureSession(
        _ session: any AudioCaptureSession,
        didFinishCapture result: RecordingResult
    ) {
        onFinish?(result)
    }
}

// MARK: - Audio Player Delegate Adapter

private final class AudioPlayerDelegateAdapter: NSObject, AVAudioPlayerDelegate, @unchecked Sendable
{
    var onFinish: (@Sendable () -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        onFinish?()
    }
}

// MARK: - Sendable Weak Reference

/// A Sendable wrapper for a weak reference to a MainActor-isolated object.
/// Used to safely pass a reference across concurrency boundaries (e.g. CoreAudio callbacks)
/// without triggering Swift 6 actor isolation traps.
private final class WeakSendableBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
