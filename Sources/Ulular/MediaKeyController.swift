import AppKit
import ApplicationServices

/// Installed on the main run loop. Consumes only volume media-key events;
/// ordinary keyboard events are not included in its event mask.
@MainActor
final class MediaKeyController {
    enum Action {
        case adjust(Float)
        case mute
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: (Action) -> Void

    init(handler: @escaping (Action) -> Void) {
        self.handler = handler
    }

    func start(requestPermission: Bool = false) -> Bool {
        guard tap == nil else { return true }
        if requestPermission {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(options) else { return false }
        } else {
            // Automatic restoration must not repeatedly display permission prompts.
            guard AXIsProcessTrusted() else { return false }
        }
        // NX_SYSDEFINED is CGEvent type 14; subtype 8 carries media keys.
        let mask = CGEventMask(1) << 14
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
            place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                // The source is attached only to CFRunLoopGetMain().
                return MainActor.assumeIsolated {
                    let controller = Unmanaged<MediaKeyController>.fromOpaque(context).takeUnretainedValue()
                    return controller.receive(type: type, event: event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    // The event tap holds an unretained pointer to self; make sure it can never outlive us.
    isolated deinit { stop() }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let keyEvent = NSEvent(cgEvent: event), keyEvent.type == .systemDefined,
              keyEvent.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
        let data = UInt32(truncatingIfNeeded: keyEvent.data1)
        let key = (data >> 16) & 0xffff
        guard key == 0 || key == 1 || key == 7 else { return Unmanaged.passUnretained(event) }
        let state = (data >> 8) & 0xff
        guard state == 0x0a || state == 0x0b else { return Unmanaged.passUnretained(event) }
        // Option alone + a volume key opens Sound settings; leave that to macOS.
        let modifiers = keyEvent.modifierFlags.intersection([.option, .shift])
        guard modifiers != .option else { return Unmanaged.passUnretained(event) }
        if state == 0x0a {
            if key == 7 {
                // A held mute key shouldn't toggle repeatedly.
                if data & 1 == 0 { handler(.mute) }
            } else {
                let fine = modifiers == [.shift, .option]
                let step: Float = fine ? 1 / 64 : 1 / 16
                handler(.adjust(key == 0 ? step : -step))
            }
        }
        // Suppress both press and release so macOS doesn't also adjust hardware
        // volume or display the unsupported-volume HUD; VolumeHUD shows ours.
        return nil
    }
}
