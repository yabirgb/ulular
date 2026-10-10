import CoreAudio
import Foundation
import AudioRealtime

protocol SoftwareVolumeRouting: AnyObject {
    var deviceID: AudioDeviceID { get }
    var aggregateID: AudioDeviceID { get }
    func setGain(_ gain: Float)
    func stop()
}

private struct RoutingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A private aggregate clocks the tap and physical output together, so gain is
/// applied directly in one HAL callback without a second playback queue.
@available(macOS 14.2, *)
final class SoftwareVolumeRouter: SoftwareVolumeRouting {
    let deviceID: AudioDeviceID
    private(set) var aggregateID: AudioDeviceID = kAudioObjectUnknown
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private var gainState: OpaquePointer?

    init(deviceID: AudioDeviceID, initialGain: Float) throws {
        self.deviceID = deviceID
        do {
            try start(initialGain: initialGain)
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    func setGain(_ gain: Float) {
        if let gainState { ULGainSet(gainState, gain) }
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            self.ioProc = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        if let gainState {
            ULGainDestroy(gainState)
            self.gainState = nil
        }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw RoutingError(message: "\(operation) failed (Core Audio \(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen ulular if permission changed.")
        }
    }

    private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) throws {
        try check(AudioProperty.read(object, AudioProperty.address(selector), into: &value), "Reading audio format")
    }

    private func channels(_ object: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var count = 0
        try check(AudioProperty.channelCount(object, scope: scope, into: &count), "Reading channel layout")
        return count
    }

    private func validateStreams(scope: AudioObjectPropertyScope, sampleRate: Double) throws {
        var streams: [AudioStreamID] = []
        try check(AudioProperty.readArray(aggregateID, AudioProperty.address(kAudioDevicePropertyStreams, scope: scope),
                                          of: AudioStreamID.self, into: &streams), "Reading streams")
        guard !streams.isEmpty else { throw RoutingError(message: "The audio route has no streams.") }
        for stream in streams {
            var format = AudioStreamBasicDescription()
            try read(stream, kAudioStreamPropertyVirtualFormat, into: &format)
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  format.mBitsPerChannel == 32,
                  format.mFramesPerPacket == 1,
                  format.mBytesPerFrame == 4 * (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : format.mChannelsPerFrame),
                  abs(format.mSampleRate - sampleRate) < 1 else {
                throw RoutingError(message: "This output's audio format isn't supported for software volume. Use stereo PCM output in Audio MIDI Setup.")
            }
        }
    }

    private func start(initialGain: Float) throws {
        // The first version deliberately rejects multichannel and input-capable
        // devices rather than risk mixing microphone buffers into playback.
        guard try channels(deviceID, scope: kAudioDevicePropertyScopeOutput) == 2,
              try channels(deviceID, scope: kAudioDevicePropertyScopeInput) == 0 else {
            throw RoutingError(message: "Software volume currently supports stereo, output-only devices such as HDMI/DisplayPort monitors. Choose stereo output in Audio MIDI Setup.")
        }
        var uid: CFString = "" as CFString
        try read(deviceID, kAudioDevicePropertyDeviceUID, into: &uid)
        var process: AudioObjectID = kAudioObjectUnknown
        var pid = getpid()
        var address = AudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), "Excluding ulular from capture")
        guard process != kAudioObjectUnknown else {
            throw RoutingError(message: "Couldn't exclude ulular from capture; routing wasn't started to avoid audio feedback.")
        }
        let description = CATapDescription(excludingProcesses: [process], deviceUID: uid as String, stream: 0)
        description.name = "ulular Software Volume"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating system audio tap")

        var format = AudioStreamBasicDescription()
        try read(tapID, kAudioTapPropertyFormat, into: &format)
        guard format.mChannelsPerFrame == 2 else {
            throw RoutingError(message: "The monitor's first output stream must be stereo for software volume.")
        }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ulular Private Audio Route",
            kAudioAggregateDeviceUIDKey: "com.musictask.route.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: uid as String,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid as String]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "Creating audio route")
        guard try channels(aggregateID, scope: kAudioDevicePropertyScopeInput) == 2,
              try channels(aggregateID, scope: kAudioDevicePropertyScopeOutput) == 2 else {
            throw RoutingError(message: "The software route didn't expose a stereo input and output.")
        }
        try validateStreams(scope: kAudioDevicePropertyScopeInput, sampleRate: format.mSampleRate)
        try validateStreams(scope: kAudioDevicePropertyScopeOutput, sampleRate: format.mSampleRate)
        guard let state = ULGainCreate(initialGain, format.mSampleRate) else {
            throw RoutingError(message: "Couldn't allocate the software volume processor.")
        }
        gainState = state
        try check(AudioDeviceCreateIOProcID(aggregateID, ULGainIOProc, UnsafeMutableRawPointer(state), &ioProc), "Creating audio processor")
        try check(AudioDeviceStart(aggregateID, ioProc), "Starting software volume")
    }
}
