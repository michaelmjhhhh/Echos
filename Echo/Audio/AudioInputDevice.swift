import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Enumerates microphone-capable devices via the Core Audio HAL.
enum AudioInputDevices {
    static func all() -> [AudioInputDevice] {
        deviceIDs().compactMap { id in
            guard !isPrivateAggregate(deviceID: id) else { return nil }
            return device(forID: id)
        }
    }

    /// Raw HAL identity, including the private devices used internally by audio
    /// engines. Capture lifecycle checks must not depend on the picker filter.
    static func device(forID id: AudioDeviceID) -> AudioInputDevice? {
        guard hasInput(id),
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return AudioInputDevice(id: id, uid: uid, name: name)
    }

    static func exists(deviceID: AudioDeviceID) -> Bool {
        device(forID: deviceID) != nil
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        guard let id = integerProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func transportType(forID id: AudioDeviceID) -> UInt32? {
        integerProperty(id, kAudioDevicePropertyTransportType)
    }

    static func isBluetooth(deviceID: AudioDeviceID) -> Bool {
        guard let transport = transportType(forID: deviceID) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func isPrivateAggregate(deviceID: AudioDeviceID) -> Bool {
        guard transportType(forID: deviceID) == kAudioDeviceTransportTypeAggregate ||
                integerProperty(deviceID, kAudioObjectPropertyClass) == kAudioAggregateDeviceClassID else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let value else { return false }
        // Core Audio transfers ownership of the returned composition object.
        let composition = value.takeRetainedValue() as NSDictionary
        return (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true
    }

    /// AVAudioEngine's default aggregates are private to the process that made
    /// them. A previously saved UID cannot reconnect after that process exits.
    static func isTransientSelection(uid: String) -> Bool {
        if uid.range(of: #"^CADefaultDeviceAggregate-[0-9]+-[0-9]+$"#, options: .regularExpression) != nil {
            return true
        }
        guard let id = deviceIDs().first(where: { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }) else {
            return false
        }
        return isPrivateAggregate(deviceID: id)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        all().first { $0.uid == uid }?.id
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func integerProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}

extension AudioInputDevices {
    static let changedNotification = Notification.Name("EchoAudioInputDevicesChanged")
}

/// Publishes changes in available inputs and the default route. The same
/// notification refreshes settings and lets active capture detect disconnects.
final class AudioInputDeviceMonitor {
    private let listener: AudioObjectPropertyListenerBlock
    private var addresses = [
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    ]

    init() {
        listener = { _, _ in
            NotificationCenter.default.post(name: AudioInputDevices.changedNotification, object: nil)
        }
        for index in addresses.indices {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[index], .main, listener)
        }
    }

    deinit {
        for index in addresses.indices {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[index], .main, listener)
        }
    }
}
