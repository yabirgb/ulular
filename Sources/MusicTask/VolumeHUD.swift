import AppKit
import SwiftUI

/// A macOS-style volume card for keys MusicTask consumes. The system card on
/// macOS 26 reads the device's hardware volume, so it can't show software gain.
@MainActor
enum VolumeHUD {
    private final class Model: ObservableObject {
        @Published var deviceName = ""
        @Published var volume: Float = 0
        @Published var muted = false
    }

    private static let model = Model()
    private static var hideTimer: Timer?
    private static let size = NSSize(width: 290, height: 62)

    private static let panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        // Also appear over full-screen video and on every Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: Card(model: model))
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect
        return panel
    }()

    static func show(volume: Float, muted: Bool, deviceName: String) {
        model.deviceName = deviceName
        model.volume = min(1, max(0, volume))
        model.muted = muted
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 10, y: frame.maxY - size.height - 8))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: false) { _ in
            Task { @MainActor in
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    // A keypress during the fade restores alpha; don't hide then.
                    Task { @MainActor in if panel.alphaValue == 0 { panel.orderOut(nil) } }
                })
            }
        }
        hideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private struct Card: View {
        @ObservedObject var model: Model

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.deviceName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.fill")
                        .frame(width: 16)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.18))
                            Capsule().fill(Color.primary)
                                .frame(width: proxy.size.width * CGFloat(model.muted ? 0 : model.volume))
                        }
                    }
                    .frame(height: 6)
                    Image(systemName: "speaker.wave.3.fill")
                        .frame(width: 20)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.muted ? "Volume muted" : "Volume \(Int((model.volume * 100).rounded())) percent")
        }
    }
}
