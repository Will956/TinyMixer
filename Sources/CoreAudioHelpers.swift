import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String
    var description: String { "\(context) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ context: String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, context: context) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)
}

enum CA {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Get property \(selector)")
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Get string \(selector)")
        return value?.takeRetainedValue() as String? ?? ""
    }

    static func objectIDs(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Get size \(selector)")
        var ids = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids), "Get list \(selector)")
        return ids
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        try value(.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID.unknown)
    }

    /// The "Play sound effects through" device, used for alerts and notification sounds.
    static func defaultSystemOutputDevice() throws -> AudioDeviceID {
        try value(.system, kAudioHardwarePropertyDefaultSystemOutputDevice, initial: AudioDeviceID.unknown)
    }

    static func deviceUID(_ device: AudioDeviceID) throws -> String {
        try string(device, kAudioDevicePropertyDeviceUID)
    }

    static func inputStreamCount(_ device: AudioDeviceID) -> Int {
        (try? objectIDs(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count) ?? 0
    }
}
