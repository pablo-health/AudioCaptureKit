import AVFoundation
import CoreAudio
import Foundation

// MARK: - Audio Source Discovery

extension CompositeCaptureSession {
    public func availableAudioSources() async throws -> [AudioSource] {
        var sources: [AudioSource] = []

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        let defaultDevice = AVCaptureDevice.default(for: .audio)

        for device in discoverySession.devices {
            sources.append(AudioSource(
                id: device.uniqueID,
                name: device.localizedName,
                type: .mic,
                isDefault: device.uniqueID == defaultDevice?.uniqueID,
                transportType: Self.transportType(forDeviceUID: device.uniqueID)
            ))
        }

        if systemCapture.isAvailable {
            sources.append(AudioSource(
                id: "system-audio",
                name: "System Audio",
                type: .system,
                isDefault: true
            ))
        }

        return sources
    }

    /// Queries CoreAudio for the transport type of a device by its UID.
    static func transportType(forDeviceUID uid: String) -> AudioTransportType {
        guard let deviceID = resolveDeviceID(forUID: uid) else {
            return .unknown
        }
        return queryTransportType(forDeviceID: deviceID)
    }

    /// Resolves a CoreAudio device ID from a device UID string.
    private static func resolveDeviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfUID: CFString = uid as CFString
        let status: OSStatus = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            withUnsafeMutablePointer(to: &deviceID) { deviceIDPtr in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(uidPtr),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(deviceIDPtr),
                    mOutputDataSize: size
                )
                var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0, nil,
                    &translationSize,
                    &translation
                )
            }
        }
        guard status == noErr else { return nil }
        return deviceID
    }

    /// Queries the transport type for a resolved CoreAudio device ID.
    private static func queryTransportType(forDeviceID deviceID: AudioDeviceID) -> AudioTransportType {
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &transportType
        )
        guard status == noErr else { return .unknown }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth:
            return .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE:
            return .bluetoothLE
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeVirtual:
            return .virtual
        default:
            return .unknown
        }
    }
}
