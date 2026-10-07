import CoreAudio

/// Thin wrappers over the Core Audio property API shared by the controller and
/// the router. They report raw statuses; callers decide how to surface errors.
enum AudioProperty {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func read<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, into value: inout T) -> OSStatus {
        var property = property
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, pointer)
        }
    }

    static func readArray<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress,
                             of _: T.Type, into values: inout [T]) -> OSStatus {
        var property = property
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size)
        guard status == noErr else { return status }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { values = []; return noErr }
        return withUnsafeTemporaryAllocation(of: T.self, capacity: count) { buffer in
            let status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, buffer.baseAddress!)
            if status == noErr { values = Array(buffer.prefix(Int(size) / MemoryLayout<T>.stride)) }
            return status
        }
    }

    static func write<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, value: T) -> OSStatus {
        var property = property
        var value = value
        return withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(object, &property, 0, nil, UInt32(MemoryLayout<T>.size), pointer)
        }
    }

    static func isSettable(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) -> Bool {
        var property = property
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(object, &property)
            && AudioObjectIsPropertySettable(object, &property, &settable) == noErr
            && settable.boolValue
    }

    static func channelCount(_ object: AudioObjectID, scope: AudioObjectPropertyScope, into count: inout Int) -> OSStatus {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size)
        guard status == noErr else { return status }
        guard size >= MemoryLayout<AudioBufferList>.size else { count = 0; return noErr }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, storage)
        guard status == noErr else { return status }
        count = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
        return noErr
    }
}
