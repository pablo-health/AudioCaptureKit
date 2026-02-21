import AVFoundation
import Foundation
import os

/// Captures microphone audio using AVFoundation.
///
/// `AVFoundationMicCapture` uses `AVCaptureSession` with the default audio
/// input device to capture what the user speaks. It handles AirPods and
/// other Bluetooth microphones seamlessly via the system's default audio
/// device routing.
///
/// Audio is delivered as mono Float32 PCM buffers.
public final class AVFoundationMicCapture: NSObject, AudioCaptureProvider, @unchecked Sendable {
    private struct State {
        var captureSession: AVCaptureSession?
        var audioOutput: AVCaptureAudioDataOutput?
        var bufferCallback: AudioBufferCallback?
        var isCapturing = false
    }

    private let state = UnfairLock(State())
    private let sessionQueue = DispatchQueue(label: "com.audiocapturekit.mic-capture")
    private let deviceID: String?

    private let logger = Logger(
        subsystem: "com.audiocapturekit",
        category: "AVFoundationMicCapture"
    )

    public init(deviceID: String? = nil) {
        self.deviceID = deviceID
        super.init()
    }

    /// Whether a microphone is available on this system.
    public var isAvailable: Bool {
        if let deviceID {
            return AVCaptureDevice(uniqueID: deviceID) != nil
        }
        return AVCaptureDevice.default(for: .audio) != nil
    }

    /// Starts capturing microphone audio.
    ///
    /// Requests microphone permission if not yet granted, then configures
    /// and starts an `AVCaptureSession` with the default audio input device.
    ///
    /// - Parameter bufferCallback: Called for each captured audio buffer.
    /// - Throws: ``CaptureError/permissionDenied`` if microphone access is denied.
    /// - Throws: ``CaptureError/deviceNotAvailable`` if no microphone is found.
    public func start(bufferCallback: @escaping AudioBufferCallback) async throws {
        let alreadyCapturing = state.withLock { $0.isCapturing }
        guard !alreadyCapturing else { return }

        try await requestMicrophonePermission()

        let device = try resolveAudioDevice()
        let session = try configureSession(device: device)

        state.withLock {
            $0.bufferCallback = bufferCallback
            $0.captureSession = session
            $0.audioOutput = nil
            $0.isCapturing = true
        }

        session.startRunning()
        logger.info("Microphone capture started")
    }

    /// Requests microphone permission, throwing if denied.
    private func requestMicrophonePermission() async throws {
        let authorized = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard authorized else {
            throw CaptureError.permissionDenied
        }
    }

    /// Resolves the audio capture device based on the configured device ID.
    private func resolveAudioDevice() throws -> AVCaptureDevice {
        if let deviceID, let specific = AVCaptureDevice(uniqueID: deviceID) {
            return specific
        }
        if let defaultDevice = AVCaptureDevice.default(for: .audio) {
            return defaultDevice
        }
        throw CaptureError.deviceNotAvailable
    }

    /// Creates and configures an `AVCaptureSession` with the given device.
    private func configureSession(device: AVCaptureDevice) throws -> AVCaptureSession {
        let session = AVCaptureSession()
        session.beginConfiguration()

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw CaptureError.configurationFailed("Cannot add audio input to capture session")
            }
            session.addInput(input)
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.configurationFailed(
                "Failed to create device input: \(error.localizedDescription)"
            )
        }

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(output) else {
            throw CaptureError.configurationFailed("Cannot add audio output to capture session")
        }
        session.addOutput(output)
        session.commitConfiguration()

        return session
    }

    /// Stops capturing microphone audio and releases the capture session.
    public func stop() async {
        let session: AVCaptureSession? = state.withLock {
            guard $0.isCapturing else { return nil }
            let current = $0.captureSession
            $0.isCapturing = false
            $0.captureSession = nil
            $0.audioOutput = nil
            $0.bufferCallback = nil
            return current
        }

        session?.stopRunning()
        logger.info("Microphone capture stopped")
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension AVFoundationMicCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        guard let streamDescription = asbd?.pointee else { return }

        let sampleRate = streamDescription.mSampleRate
        let channelCount = streamDescription.mChannelsPerFrame

        guard let pcmBuffer = sampleBuffer.toPCMBuffer(
            sampleRate: sampleRate,
            channelCount: channelCount
        ) else { return }

        let audioTime = AVAudioTime(
            sampleTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value,
            atRate: sampleRate
        )

        let callback = state.withLock { $0.bufferCallback }
        callback?(pcmBuffer, audioTime)
    }
}

// MARK: - CMSampleBuffer Extension

extension CMSampleBuffer {
    /// Converts a CMSampleBuffer to an AVAudioPCMBuffer.
    func toPCMBuffer(sampleRate: Double, channelCount: UInt32) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return nil }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else { return nil }

        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let rawData = dataPointer else { return nil }

        if let channelData = pcmBuffer.floatChannelData {
            let floatData = UnsafeRawPointer(rawData).assumingMemoryBound(to: Float.self)
            let sampleCount = min(
                frameCount,
                totalLength / MemoryLayout<Float>.size / Int(channelCount)
            )
            for frame in 0..<sampleCount {
                for channel in 0..<Int(channelCount) {
                    channelData[channel][frame] = floatData[frame * Int(channelCount) + channel]
                }
            }
        }

        return pcmBuffer
    }
}
