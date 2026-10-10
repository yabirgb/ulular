import AppKit
import SwiftUI

@main
struct Ulular {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var audio: AudioController!
    private let loginItem = LoginItemController()
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        audio = AudioController()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = UlularLogo.menuBarImage()
            button.toolTip = "ulular — Audio output and volume"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 340, height: 500)
        popover.contentViewController = NSHostingController(rootView: AudioPanel(audio: audio, loginItem: loginItem))
    }

    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        loginItem.refresh()
    }

    private func togglePopover() {
        loginItem.refresh()
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            // .transient misses clicks in other apps while an accessory app isn't frontmost.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.popover.performClose(nil) }
            }
        }
    }

    private func showContextMenu() {
        if popover.isShown { popover.performClose(nil) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let menu = NSMenu()
        let title = NSMenuItem(title: version.map { "ulular \($0)" } ?? "ulular", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        loginItem.refresh()
        let settings = NSMenu()
        let startAtLogin = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        startAtLogin.target = self
        startAtLogin.state = loginItem.isEnabled ? .on : .off
        settings.addItem(startAtLogin)
        if loginItem.requiresApproval {
            let approval = NSMenuItem(title: "Approve in System Settings…", action: #selector(openLoginSettings), keyEquivalent: "")
            approval.target = self
            settings.addItem(approval)
        }
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settings
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ulular", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // Attach the menu only for this click so left-click keeps opening the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleStartAtLogin() {
        loginItem.setEnabled(!loginItem.isEnabled)
        if let message = loginItem.errorMessage {
            let alert = NSAlert()
            alert.messageText = "Login Item Could Not Be Updated"
            alert.informativeText = message
            alert.runModal()
            loginItem.errorMessage = nil
        }
    }

    @objc private func openLoginSettings() {
        loginItem.openLoginSettings()
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    @objc private func willSleep() {
        audio.prepareForSleep()
    }

    @objc private func didWake() {
        // Allow physical outputs to reconnect before attempting to rebuild the route.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.audio.resumeAfterWake()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        audio.stop()
    }
}

private struct AudioPanel: View {
    @ObservedObject var audio: AudioController
    @ObservedObject var loginItem: LoginItemController
    @State private var showSoftwareConsent = false
    @State private var showStopWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(nsImage: UlularLogo.menuBarImage())
                    .interpolation(.none)
                    .accessibilityHidden(true)
                Text("ulular")
                    .font(.headline)
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain)
                .help("Quit ulular")
                .accessibilityLabel("Quit ulular")
            }

            TabView {
                audioContent
                    .padding(12)
                    .tabItem { Label("Audio", systemImage: "speaker.wave.2.fill") }
                settingsContent
                    .padding(12)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
        }
        .padding(16)
        .frame(width: 340, height: 500)
        .alert("Login Item Could Not Be Updated", isPresented: Binding(
            get: { loginItem.errorMessage != nil },
            set: { if !$0 { loginItem.errorMessage = nil } }
        )) {
            Button("OK") { loginItem.errorMessage = nil }
        } message: {
            Text(loginItem.errorMessage ?? "")
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Start at Login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            Text("Automatically open ulular when you sign in to your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if loginItem.requiresApproval {
                Text("macOS requires approval before ulular can start at login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Approve in System Settings…") { loginItem.openLoginSettings() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { loginItem.refresh() }
    }

    private var audioContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(audio.devices) { device in
                        Button { audio.selectDevice(device.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "hifispeaker.fill")
                                    .foregroundStyle(.secondary)
                                Text(device.name)
                                    .lineLimit(2)
                                Spacer(minLength: 4)
                                if device.id == audio.selectedID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(device.id == audio.selectedID ? Color.accentColor.opacity(0.12) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(device.id == audio.selectedID ? [.isSelected] : [])
                    }
                    if audio.devices.isEmpty {
                        Text("No audio output devices available.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            HStack {
                Text("Volume").font(.subheadline.weight(.medium))
                Spacer()
                Text(audio.canAdjustVolume ? "\(Int((audio.volume * 100).rounded()))%" : "Fixed")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { audio.toggleMute() } label: {
                    Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .disabled(!audio.canMute)
                .help(audio.isMuted ? "Unmute" : "Mute")
                .accessibilityLabel(audio.isMuted ? "Unmute" : "Mute")
                Slider(value: Binding(get: { Double(audio.volume) }, set: { audio.setVolume(Float($0)) }), in: 0...1)
                    .disabled(!audio.canAdjustVolume)
                    .accessibilityLabel("Output volume")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            if audio.softwareVolumeEnabled {
                HStack {
                    Label("Software volume active", systemImage: "waveform")
                        .font(.caption)
                    Spacer()
                    Button("Stop") { showStopWarning = true }
                        .font(.caption)
                }
                if audio.keyboardControlsEnabled {
                    HStack {
                        Label("Volume keys enabled", systemImage: "keyboard")
                            .font(.caption)
                        Spacer()
                        Button("Disable") { audio.disableKeyboardControls() }
                            .font(.caption)
                    }
                } else if audio.keyboardControlsPreferred {
                    HStack {
                        Label("Waiting for keyboard access", systemImage: "keyboard")
                            .font(.caption)
                        Spacer()
                        Button("Cancel") { audio.disableKeyboardControls() }
                            .font(.caption)
                    }
                    Button("Grant Keyboard Access…") { audio.enableKeyboardControls() }
                        .font(.caption)
                } else {
                    Button("Enable Keyboard Controls…") { audio.enableKeyboardControls() }
                        .help("Requires Accessibility permission. Your choice is remembered for future software-volume sessions.")
                }
                if let message = audio.keyboardControlsMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Audio is processed by ulular. Stopping, quitting, or switching devices restores unattenuated playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !audio.canAdjustVolume && !audio.devices.isEmpty {
                Text("This output has no hardware volume control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if audio.softwareVolumeAvailable {
                    Button("Enable Software Volume…") { showSoftwareConsent = true }
                } else {
                    Text("Software volume requires macOS 14.2 or newer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = audio.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Enable software volume?", isPresented: $showSoftwareConsent) {
            Button("Cancel", role: .cancel) {}
            Button("Enable") { audio.enableSoftwareVolume() }
        } message: {
            Text("ulular will capture system audio locally and replay this output at a reduced level, starting at 25% on first use. This may add latency. Your choice, volume, and mute state will be remembered for this monitor and restored when reopening or reconnecting. Keyboard volume controls activate automatically if Accessibility permission is granted. Quitting, stopping, or changing outputs can restore the device's normal volume, which may be much louder. Turn down your monitor's physical volume first.")
        }
        .alert("Restore normal playback?", isPresented: $showStopWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Stop Software Volume", role: .destructive) { audio.disableSoftwareVolume() }
        } message: {
            Text("Playback will return to the monitor's unattenuated volume, and automatic activation will be disabled for this monitor. Turn down its physical volume before continuing.")
        }
    }
}
