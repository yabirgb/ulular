import AppKit
import CoreAudio
import AppSettings

struct OutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}

/// Core Audio's default output is the destination for normal application audio.
/// Notification/alert sounds use a separate "system output" device, so both are
/// set together; otherwise those sounds bypass the selected device (and its tap).
@MainActor
final class AudioController: ObservableObject {
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var selectedID: AudioDeviceID = kAudioObjectUnknown
    @Published private(set) var volume: Float = 0
    @Published private(set) var canAdjustVolume = false
    @Published private(set) var isMuted = false
    @Published private(set) var canMute = false
    @Published var errorMessage: String?
    @Published private(set) var softwareVolumeEnabled = false
    @Published private(set) var keyboardControlsEnabled = false
    @Published private(set) var keyboardControlsPreferred = false
    private let preferences = AudioPreferences()
    private var routeUID: String?
    private var lastSelectedUID: String?
    private var restoreAttemptedUID: String?
    private var isSleeping = false
    private var isStopping = false
    @Published private(set) var keyboardControlsMessage: String?
    private var keyboardPermissionTimer: Timer?

    private lazy var mediaKeys = MediaKeyController { [weak self] action in
        guard let self, self.softwareVolumeEnabled else { return }
        switch action {
        case .mute:
            self.toggleMute()
        case .adjust(let step):
            if self.softwareMuted { self.toggleMute() }
            self.setVolume(self.softwareLevel + step)
        }
        VolumeHUD.show(volume: self.softwareLevel, muted: self.softwareMuted,
                       deviceName: self.devices.first { $0.id == self.selectedID }?.name ?? "Output")
    }

    var softwareVolumeAvailable: Bool {
        if #available(macOS 14.2, *) {
            return selectedID != kAudioObjectUnknown && (softwareVolumeEnabled || volumeElements.isEmpty)
        }
        return false
    }

    private var softwareRouter: SoftwareVolumeRouting?
    private var softwareLevel: Float = 0.25
    private var softwareMuted = false

    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var hardwareListeners: [Listener] = []
    private var deviceListeners: [Listener] = []
    private var volumeElements: [AudioObjectPropertyElement] = []
    private var muteElements: [AudioObjectPropertyElement] = []
    private let system = AudioObjectID(kAudioObjectSystemObject)

    init() {
        keyboardControlsPreferred = preferences.keyboardPreferred
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            listen(object: system, address: address(selector), hardware: true)
        }
        refreshDevices()
    }

    func stop() {
        isStopping = true
        disableSoftwareVolume(forgetPreference: false)
        removeListeners(&deviceListeners)
        removeListeners(&hardwareListeners)
    }

    private func address(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioProperty.address(selector, scope: scope, element: element)
    }

    private func read<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, into value: inout T) -> OSStatus {
        AudioProperty.read(object, property, into: &value)
    }

    private func write<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, value: T) -> Bool {
        let status = AudioProperty.write(object, property, value: value)
        if status != noErr {
            errorMessage = "Couldn't update the audio device (Core Audio error \(status))."
            return false
        }
        errorMessage = nil
        return true
    }

    private func outputChannels(_ device: AudioDeviceID) -> Int {
        var count = 0
        return AudioProperty.channelCount(device, scope: kAudioDevicePropertyScopeOutput, into: &count) == noErr ? count : 0
    }

    private func refreshDevices() {
        var ids: [AudioDeviceID] = []
        let status = AudioProperty.readArray(system, address(kAudioHardwarePropertyDevices), of: AudioDeviceID.self, into: &ids)
        guard status == noErr else {
            errorMessage = "Couldn't read the available audio devices (Core Audio error \(status))."
            return
        }
        devices = ids.compactMap { id in
            guard id != softwareRouter?.aggregateID, outputChannels(id) > 0 else { return nil }
            var uid: CFString = "" as CFString
            _ = read(id, address(kAudioDevicePropertyDeviceUID), into: &uid)
            guard !(uid as String).hasPrefix("com.musictask.route.") else { return nil }
            var name: CFString = "Audio device" as CFString
            _ = read(id, address(kAudioObjectPropertyName), into: &name)
            return OutputDevice(id: id, name: name as String)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var current: AudioDeviceID = kAudioObjectUnknown
        _ = read(system, address(kAudioHardwarePropertyDefaultOutputDevice), into: &current)
        if let router = softwareRouter {
            var alive: UInt32 = 0
            let status = read(router.deviceID, address(kAudioDevicePropertyDeviceIsAlive), into: &alive)
            if current != router.deviceID || !devices.contains(where: { $0.id == router.deviceID }) || status != noErr || alive == 0 {
                disableSoftwareVolume(forgetPreference: false)
                restoreAttemptedUID = nil
            }
        }
        selectedID = current
        removeListeners(&deviceListeners)
        if current != kAudioObjectUnknown {
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute,
                             kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyDeviceIsAlive,
                             kAudioDevicePropertyNominalSampleRate] {
                let scope = (selector == kAudioDevicePropertyDeviceIsAlive || selector == kAudioDevicePropertyNominalSampleRate)
                    ? kAudioObjectPropertyScopeGlobal : kAudioDevicePropertyScopeOutput
                listen(object: current,
                       address: address(selector, scope: scope, element: kAudioObjectPropertyElementWildcard),
                       hardware: false)
            }
        }
        refreshVolume()
        let uid = selectedDeviceUID()
        if uid != lastSelectedUID {
            lastSelectedUID = uid
            restoreAttemptedUID = nil
        }
        restoreSoftwareVolumeIfNeeded()
    }

    private func selectedDeviceUID() -> String? {
        guard selectedID != kAudioObjectUnknown else { return nil }
        var uid: CFString = "" as CFString
        guard read(selectedID, address(kAudioDevicePropertyDeviceUID), into: &uid) == noErr,
              !(uid as String).isEmpty else { return nil }
        return uid as String
    }

    private func restoreSoftwareVolumeIfNeeded() {
        guard !isStopping, !isSleeping, !softwareVolumeEnabled, softwareVolumeAvailable,
              let uid = selectedDeviceUID(), restoreAttemptedUID != uid,
              preferences.output(for: uid).enabled else { return }
        var alive: UInt32 = 0
        guard read(selectedID, address(kAudioDevicePropertyDeviceIsAlive), into: &alive) == noErr, alive != 0 else { return }
        // Attempt once per device selection, not on every aggregate-device event.
        // A failed permission/format check must not trigger an endless rebuild loop.
        restoreAttemptedUID = uid
        enableSoftwareVolume()
    }

    private var softwareSettings: SoftwareOutputSettings {
        SoftwareOutputSettings(enabled: softwareVolumeEnabled, volume: softwareLevel, muted: softwareMuted)
    }

    private func persistSoftwareSettings(enabled: Bool = true) {
        guard let routeUID else { return }
        var settings = softwareSettings
        settings.enabled = enabled
        preferences.save(settings, for: routeUID)
    }

    func prepareForSleep() {
        isSleeping = true
        disableSoftwareVolume(forgetPreference: false)
    }

    func resumeAfterWake() {
        guard !isStopping else { return }
        isSleeping = false
        restoreAttemptedUID = nil
        refreshDevices()
    }

    private func controllableElements(_ selector: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
        let master = address(selector, scope: kAudioDevicePropertyScopeOutput)
        if AudioProperty.isSettable(selectedID, master) { return [kAudioObjectPropertyElementMain] }
        let count = outputChannels(selectedID)
        guard count > 0 else { return [] }
        return (1...count).map { AudioObjectPropertyElement($0) }.filter {
            AudioProperty.isSettable(selectedID, address(selector, scope: kAudioDevicePropertyScopeOutput, element: $0))
        }
    }

    private func refreshVolume() {
        if softwareVolumeEnabled {
            volume = softwareLevel
            isMuted = softwareMuted
            canAdjustVolume = true
            canMute = true
            return
        }
        guard selectedID != kAudioObjectUnknown else {
            volumeElements = []; muteElements = []
            canAdjustVolume = false; canMute = false; volume = 0; isMuted = false
            return
        }
        volumeElements = controllableElements(kAudioDevicePropertyVolumeScalar)
        muteElements = controllableElements(kAudioDevicePropertyMute)
        canAdjustVolume = !volumeElements.isEmpty
        canMute = !muteElements.isEmpty
        let values: [Float32] = volumeElements.compactMap { element in
            var value: Float32 = 0
            return read(selectedID, address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element), into: &value) == noErr ? value : nil
        }
        volume = values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count)
        isMuted = !muteElements.isEmpty && muteElements.allSatisfy { element in
            var value: UInt32 = 0
            return read(selectedID, address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: element), into: &value) == noErr && value != 0
        }
    }

    func selectDevice(_ id: AudioDeviceID) {
        if id != selectedID { disableSoftwareVolume(forgetPreference: false) }
        if write(system, address(kAudioHardwarePropertyDefaultOutputDevice), value: id) {
            _ = write(system, address(kAudioHardwarePropertyDefaultSystemOutputDevice), value: id)
        }
        refreshDevices()
    }

    func setVolume(_ value: Float) {
        let clamped = min(1, max(0, value))
        if let router = softwareRouter {
            softwareLevel = clamped
            router.setGain(softwareSettings.gain)
            persistSoftwareSettings()
            refreshVolume()
            return
        }
        for element in volumeElements {
            if !write(selectedID, address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element), value: clamped) { break }
        }
        refreshVolume()
    }

    func toggleMute() {
        if let router = softwareRouter {
            softwareMuted.toggle()
            router.setGain(softwareSettings.gain)
            persistSoftwareSettings()
            refreshVolume()
            return
        }
        let value: UInt32 = isMuted ? 0 : 1
        for element in muteElements {
            if !write(selectedID, address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: element), value: value) { break }
        }
        refreshVolume()
    }

    func enableSoftwareVolume() {
        guard softwareRouter == nil, softwareVolumeAvailable else { return }
        guard #available(macOS 14.2, *), let uid = selectedDeviceUID() else { return }
        restoreAttemptedUID = uid
        let saved = preferences.output(for: uid)
        do {
            softwareLevel = saved.volume
            softwareMuted = saved.muted
            softwareRouter = try SoftwareVolumeRouter(deviceID: selectedID, initialGain: saved.gain)
            routeUID = uid
            softwareVolumeEnabled = true
            persistSoftwareSettings()
            errorMessage = nil
            refreshVolume()
            restoreKeyboardControls()
        } catch {
            errorMessage = error.localizedDescription
            refreshVolume()
        }
    }

    func enableKeyboardControls() {
        guard softwareVolumeEnabled else { return }
        keyboardControlsPreferred = true
        preferences.keyboardPreferred = true
        restoreKeyboardControls(requestPermission: true)
    }

    private func restoreKeyboardControls(requestPermission: Bool = false) {
        guard softwareVolumeEnabled, keyboardControlsPreferred else { return }
        if mediaKeys.start(requestPermission: requestPermission) {
            keyboardControlsEnabled = true
            keyboardControlsMessage = nil
            keyboardPermissionTimer?.invalidate()
            keyboardPermissionTimer = nil
        } else {
            keyboardControlsMessage = "Allow MusicTask in System Settings → Privacy & Security → Accessibility. Controls will activate automatically once permission is available. macOS may require quitting and reopening MusicTask."
            guard keyboardPermissionTimer == nil else { return }
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.restoreKeyboardControls()
                }
            }
            keyboardPermissionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func disableKeyboardControls() {
        keyboardControlsPreferred = false
        preferences.keyboardPreferred = false
        suspendKeyboardControls()
    }

    private func suspendKeyboardControls() {
        keyboardPermissionTimer?.invalidate()
        keyboardPermissionTimer = nil
        mediaKeys.stop()
        keyboardControlsEnabled = false
        keyboardControlsMessage = nil
    }

    func disableSoftwareVolume(forgetPreference: Bool = true) {
        // Explicit Stop forgets activation; lifecycle interruptions preserve it.
        persistSoftwareSettings(enabled: !forgetPreference)
        suspendKeyboardControls()
        softwareRouter?.stop()
        softwareRouter = nil
        routeUID = nil
        softwareVolumeEnabled = false
        softwareMuted = false
        refreshVolume()
    }

    private func listen(object: AudioObjectID, address: AudioObjectPropertyAddress, hardware: Bool) {
        var property = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard hardware || object == self.selectedID else { return }
                if hardware {
                    self.refreshDevices()
                } else if address.mSelector == kAudioDevicePropertyDeviceIsAlive {
                    self.refreshDevices()
                } else if address.mSelector == kAudioDevicePropertyNominalSampleRate || address.mSelector == kAudioDevicePropertyStreamConfiguration {
                    if self.softwareVolumeEnabled {
                        self.disableSoftwareVolume(forgetPreference: false)
                        self.errorMessage = "The audio format changed. Software volume stopped; enable it again for the new format."
                    }
                    self.refreshDevices()
                } else {
                    self.refreshVolume()
                }
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &property, DispatchQueue.main, block) == noErr {
            let listener = Listener(object: object, address: address, block: block)
            if hardware { hardwareListeners.append(listener) } else { deviceListeners.append(listener) }
        }
    }

    private func removeListeners(_ listeners: inout [Listener]) {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, DispatchQueue.main, listener.block)
        }
        listeners.removeAll()
    }
}
