import CoreAudio
import Foundation

struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioInputDeviceError: Error, LocalizedError {
    case listFailed(OSStatus)
    case readFailed(String, OSStatus)
    case deviceUnavailable(String)
    case selectFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .listFailed(let status):
            return "Could not list microphones. CoreAudio status: \(status)."
        case .readFailed(let field, let status):
            return "Could not read microphone \(field). CoreAudio status: \(status)."
        case .deviceUnavailable(let uid):
            return "The selected microphone is not available: \(uid)."
        case .selectFailed(let name, let status):
            return "Could not select \(name). CoreAudio status: \(status)."
        }
    }
}

enum AudioInputDeviceManager {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private static let mainElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)

    static func inputDevices() throws -> [AudioInputDevice] {
        var address = propertyAddress(
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw AudioInputDeviceError.listFailed(status)
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
        status = deviceIDs.withUnsafeMutableBufferPointer { pointer in
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, pointer.baseAddress!)
        }
        guard status == noErr else {
            throw AudioInputDeviceError.listFailed(status)
        }

        let devices = try deviceIDs.compactMap { deviceID -> AudioInputDevice? in
            guard try hasInputStreams(deviceID) else { return nil }
            let name = try stringProperty(
                deviceID,
                selector: kAudioObjectPropertyName,
                scope: kAudioObjectPropertyScopeGlobal,
                field: "name"
            )
            let uid = try stringProperty(
                deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal,
                field: "uid"
            )
            return AudioInputDevice(id: deviceID, uid: uid, name: name)
        }

        return devices.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func defaultInputDevice() throws -> AudioInputDevice? {
        var address = propertyAddress(
            selector: kAudioHardwarePropertyDefaultInputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceID)
        guard status == noErr else {
            throw AudioInputDeviceError.readFailed("default input", status)
        }
        return try inputDevices().first { $0.id == deviceID }
    }

    static func device(uid: String) throws -> AudioInputDevice? {
        try inputDevices().first { $0.uid == uid }
    }

    @discardableResult
    static func applySelectedInput(uid: String?) throws -> AudioInputDevice? {
        guard let uid, !uid.isEmpty else {
            return try defaultInputDevice()
        }

        guard let device = try device(uid: uid) else {
            throw AudioInputDeviceError.deviceUnavailable(uid)
        }

        try setDefaultInputDevice(device)
        return device
    }

    private static func setDefaultInputDevice(_ device: AudioInputDevice) throws {
        var address = propertyAddress(
            selector: kAudioHardwarePropertyDefaultInputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        )
        var deviceID = device.id
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(systemObject, &address, 0, nil, dataSize, &deviceID)
        guard status == noErr else {
            throw AudioInputDeviceError.selectFailed(device.name, status)
        }
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) throws -> Bool {
        var address = propertyAddress(
            selector: kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeInput
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw AudioInputDeviceError.readFailed("input streams", status)
        }
        return dataSize > 0
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        field: String
    ) throws -> String {
        var address = propertyAddress(selector: selector, scope: scope)
        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutableBytes(of: &value) { rawBuffer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawBuffer.baseAddress!)
        }
        guard status == noErr else {
            throw AudioInputDeviceError.readFailed(field, status)
        }
        guard let value else {
            throw AudioInputDeviceError.readFailed(field, status)
        }
        return value as String
    }

    private static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: mainElement
        )
    }
}
