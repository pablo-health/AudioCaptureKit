import AVFoundation
import CoreAudio
import Foundation
import os

/// Captures system audio using the Core Audio Tap API (macOS 14.2+).
///
/// Uses `CATapDescription` + `AudioHardwareCreateProcessTap` to tap system audio,
/// then wraps the tap in an **aggregate device** for I/O. The aggregate device
/// pattern is required because the tap device cannot be read from directly.
///
/// **Permissions required:**
/// - "Screen & System Audio Recording" in System Settings > Privacy & Security.
///
/// Based on the approach documented in [AudioCap](https://github.com/insidegui/AudioCap).
public final class CoreAudioTapCapture: AudioCaptureProvider, @unchecked Sendable {
    private struct State {
        var bufferCallback: AudioBufferCallback?
        var isCapturing = false
        var tapID: AudioObjectID = kAudioObjectUnknown
        var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
        var ioProcID: AudioDeviceIOProcID?
        var sampleRate: Double = 48000
        var tapStreamFormat: AudioStreamBasicDescription?
    }

    private let state = UnfairLock(State())
    private let ioQueue = DispatchQueue(label: "com.audiocapturekit.system-audio-io", qos: .userInitiated)

    private let logger = Logger(subsystem: "com.audiocapturekit", category: "CoreAudioTapCapture")

    public init() {}

    /// Whether the Core Audio Tap API is available on this macOS version.
    public var isAvailable: Bool {
        if #available(macOS 14.2, *) {
            return true
        }
        return false
    }

    /// Starts capturing system audio.
    ///
    /// Creates a process tap, wraps it in an aggregate device, and starts
    /// reading audio buffers via an I/O proc on the aggregate device.
    ///
    /// - Parameter bufferCallback: Called for each captured audio buffer.
    /// - Throws: ``CaptureError/configurationFailed(_:)`` if the tap or aggregate device cannot be created.
    public func start(bufferCallback: @escaping AudioBufferCallback) async throws {
        guard isAvailable else {
            throw CaptureError.configurationFailed("Core Audio Tap requires macOS 14.2+")
        }

        let alreadyCapturing = state.withLock { $0.isCapturing }
        guard !alreadyCapturing else { return }

        if #available(macOS 14.2, *) {
            try startTap(callback: bufferCallback)
        }

        logger.info("System audio capture started")
    }

    /// Stops capturing system audio and releases the tap and aggregate device.
    public func stop() async {
        if #available(macOS 14.2, *) {
            stopTap()
        }
        logger.info("System audio capture stopped")
    }

    // MARK: - Private

    @available(macOS 14.2, *)
    private func startTap(callback: @escaping AudioBufferCallback) throws {
        let (tapID, tapDescription) = try createProcessTap()
        let outputUID = try Self.defaultOutputDeviceUID()

        let tapFormat = Self.readTapFormat(tapID)
        let sampleRate = tapFormat?.mSampleRate ?? Self.queryDeviceSampleRate(tapID)

        let aggregateDeviceID = try createAggregateDevice(
            outputUID: outputUID,
            tapUUID: tapDescription.uuid,
            tapID: tapID
        )

        let (actualSampleRate, resolvedFormat) = resolveAggregateFormat(
            aggregateDeviceID: aggregateDeviceID,
            tapFormat: tapFormat,
            tapSampleRate: sampleRate
        )

        state.withLock {
            $0.bufferCallback = callback
            $0.tapID = tapID
            $0.aggregateDeviceID = aggregateDeviceID
            $0.sampleRate = actualSampleRate
            $0.tapStreamFormat = resolvedFormat
        }

        try startAggregateIO(
            aggregateDeviceID: aggregateDeviceID,
            tapID: tapID
        )
    }

    /// Creates a Core Audio process tap for all system audio.
    @available(macOS 14.2, *)
    private func createProcessTap() throws -> (AudioObjectID, CATapDescription) {
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.name = "AudioCaptureKit System Audio"

        var tapID: AudioObjectID = kAudioObjectUnknown
        let createStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        guard createStatus == noErr, tapID != kAudioObjectUnknown else {
            throw CaptureError.configurationFailed(
                "Failed to create process tap: OSStatus \(createStatus)"
            )
        }

        logger.info("Created process tap: \(tapID)")
        return (tapID, tapDescription)
    }

    /// Creates an aggregate device wrapping the given tap and output device.
    @available(macOS 14.2, *)
    private func createAggregateDevice(
        outputUID: String,
        tapUUID: UUID,
        tapID: AudioObjectID
    ) throws -> AudioObjectID {
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioCaptureKit-SystemAudio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                ],
            ],
        ]

        var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(
            description as CFDictionary, &aggregateDeviceID
        )

        guard status == noErr, aggregateDeviceID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.configurationFailed(
                "Failed to create aggregate device: OSStatus \(status)"
            )
        }

        logger.info("Created aggregate device: \(aggregateDeviceID)")
        return aggregateDeviceID
    }

    /// Resolves the actual sample rate and stream format from the aggregate device.
    private func resolveAggregateFormat(
        aggregateDeviceID: AudioObjectID,
        tapFormat: AudioStreamBasicDescription?,
        tapSampleRate: Double
    ) -> (sampleRate: Double, format: AudioStreamBasicDescription?) {
        let aggregateFormat = Self.readDeviceInputFormat(aggregateDeviceID)
        let actualSampleRate = aggregateFormat?.mSampleRate ?? tapSampleRate
        let aggChannels = aggregateFormat?.mChannelsPerFrame ?? 0
        logger.info(
            "Aggregate format: rate=\(actualSampleRate), ch=\(aggChannels), tapRate=\(tapSampleRate)"
        )
        // Prefer the aggregate device's format over the tap format,
        // since the IO callback delivers data in the aggregate's format.
        return (actualSampleRate, aggregateFormat ?? tapFormat)
    }

    /// Creates an I/O proc on the aggregate device and starts audio I/O.
    private func startAggregateIO(
        aggregateDeviceID: AudioObjectID,
        tapID: AudioObjectID
    ) throws {
        var ioProcID: AudioDeviceIOProcID?

        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID, aggregateDeviceID, ioQueue
        ) { [weak self] _, inInputData, inInputTime, _, _ in
            self?.handleIOBuffer(inInputData: inInputData, inInputTime: inInputTime)
        }

        guard ioStatus == noErr, let procID = ioProcID else {
            tearDownAudioResources(aggregateID: aggregateDeviceID, tapID: tapID)
            throw CaptureError.configurationFailed(
                "Failed to create I/O proc: OSStatus \(ioStatus)"
            )
        }

        state.withLock {
            $0.ioProcID = procID
            $0.isCapturing = true
        }

        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            tearDownAudioResources(aggregateID: aggregateDeviceID, tapID: tapID)
            throw CaptureError.configurationFailed(
                "Failed to start aggregate device: OSStatus \(startStatus)"
            )
        }
    }

    /// Destroys the aggregate device and process tap, resetting state.
    private func tearDownAudioResources(
        aggregateID: AudioObjectID,
        tapID: AudioObjectID
    ) {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
        }
        state.withLock {
            $0.tapID = kAudioObjectUnknown
            $0.aggregateDeviceID = kAudioObjectUnknown
            $0.ioProcID = nil
            $0.isCapturing = false
            $0.bufferCallback = nil
        }
    }

    @available(macOS 14.2, *)
    private func stopTap() {
        let (tapID, aggregateID, ioProcID) = state.withLock { current in
            let tap = current.tapID
            let aggregate = current.aggregateDeviceID
            let proc = current.ioProcID
            current.isCapturing = false
            current.bufferCallback = nil
            current.tapID = kAudioObjectUnknown
            current.aggregateDeviceID = kAudioObjectUnknown
            current.ioProcID = nil
            return (tap, aggregate, proc)
        }

        // Tear down in reverse order: stop -> destroy IO proc -> destroy aggregate -> destroy tap
        if aggregateID != kAudioObjectUnknown {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    // MARK: - I/O Buffer Handling

    private func handleIOBuffer(
        inInputData: UnsafePointer<AudioBufferList>,
        inInputTime: UnsafePointer<AudioTimeStamp>
    ) {
        let (callback, sampleRate, tapFormat) = state.withLock {
            ($0.bufferCallback, $0.sampleRate, $0.tapStreamFormat)
        }
        guard let callback else { return }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inInputData)
        )

        guard let firstBuffer = bufferList.first,
              firstBuffer.mData != nil else { return }

        // Use the tap's stream description to create the format (like AudioCap does),
        // rather than guessing from buffer metadata. This ensures the interleaved flag
        // and channel layout match the actual data.
        let format: AVAudioFormat
        if var desc = tapFormat {
            guard let tapAudioFormat = AVAudioFormat(streamDescription: &desc) else { return }
            format = tapAudioFormat
        } else {
            // Fallback: infer from buffer metadata
            let channelCount = firstBuffer.mNumberChannels
            guard let inferredFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            ) else { return }
            format = inferredFormat
        }

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: inInputData,
            deallocator: nil
        ) else { return }

        let audioTime = AVAudioTime(
            sampleTime: Int64(inInputTime.pointee.mSampleTime),
            atRate: sampleRate
        )

        callback(pcmBuffer, audioTime)
    }

}

// MARK: - Core Audio Helpers

extension CoreAudioTapCapture {
    static func queryDeviceSampleRate(_ deviceID: AudioObjectID) -> Double {
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        guard status == noErr, sampleRate > 0 else { return 48000 }
        return sampleRate
    }

    static func readDeviceInputFormat(_ deviceID: AudioObjectID) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &format)
        guard status == noErr else { return nil }
        return format
    }

    static func readTapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { return nil }
        return format
    }

    static func defaultOutputDeviceUID() throws -> String {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else {
            throw CaptureError.configurationFailed(
                "Failed to get default output device: OSStatus \(status)"
            )
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uidString = uid?.takeUnretainedValue() as String? else {
            throw CaptureError.configurationFailed(
                "Failed to get output device UID: OSStatus \(status)"
            )
        }

        return uidString
    }
}
