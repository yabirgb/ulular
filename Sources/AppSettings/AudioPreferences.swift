import Foundation

public struct SoftwareOutputSettings: Equatable {
    public var enabled: Bool
    /// Slider position (0...1), not the linear gain applied to samples.
    public var volume: Float
    public var muted: Bool

    public init(enabled: Bool = false, volume: Float = 0.25, muted: Bool = false) {
        self.enabled = enabled
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 0.25
        self.muted = muted
    }

    /// Hearing is logarithmic, so a linear multiplier crowds most of the audible
    /// change into the bottom of the slider. A cubic taper spreads it evenly
    /// (25% ≈ −36 dB, 50% ≈ −18 dB) and still reaches true silence at 0.
    public static func gain(forLevel level: Float) -> Float {
        let level = level.isFinite ? min(1, max(0, level)) : 0
        return level * level * level
    }

    /// Linear gain to send to the audio processor; silence while muted.
    public var gain: Float { muted ? 0 : Self.gain(forLevel: volume) }
}

/// Explicit preferences domain stays the same for bundled and development runs.
/// Device UIDs, unlike AudioDeviceIDs, survive reconnects and application restarts.
/// Settings are stored as a native property-list dictionary and cached in memory,
/// so saving on every slider change doesn't re-decode the whole store.
public final class AudioPreferences {
    public static let domain = "com.musictask.app"

    private let defaults: UserDefaults
    private let outputsKey = "softwareOutputs"
    private let legacyOutputsKey = "softwareOutputSettings"
    private let keyboardKey = "keyboardControlsPreferred"
    private var outputs: [String: SoftwareOutputSettings]

    public init(defaults: UserDefaults? = nil) {
        if let defaults {
            self.defaults = defaults
        } else if Bundle.main.bundleIdentifier == Self.domain {
            // Foundation rejects using our own application domain as a suite.
            // Standard defaults already use that domain in the bundled app.
            self.defaults = .standard
        } else {
            // Development/test executables have a different application domain.
            self.defaults = UserDefaults(suiteName: Self.domain) ?? .standard
        }
        outputs = [:]
        load()
    }

    public var keyboardPreferred: Bool {
        get {
            // Keyboard control accompanies software volume unless explicitly disabled.
            defaults.object(forKey: keyboardKey) == nil ? true : defaults.bool(forKey: keyboardKey)
        }
        set { defaults.set(newValue, forKey: keyboardKey) }
    }

    public func output(for uid: String) -> SoftwareOutputSettings {
        outputs[uid] ?? SoftwareOutputSettings()
    }

    public func save(_ state: SoftwareOutputSettings, for uid: String) {
        guard outputs[uid] != state else { return }
        outputs[uid] = state
        defaults.set(outputs.mapValues { ["enabled": $0.enabled, "volume": Double($0.volume), "muted": $0.muted] },
                     forKey: outputsKey)
    }

    private func load() {
        if let stored = defaults.dictionary(forKey: outputsKey) {
            for case let (uid, value as [String: Any]) in stored {
                // NSNumber → Float bridging fails for inexact values, so read via NSNumber.
                outputs[uid] = SoftwareOutputSettings(
                    enabled: value["enabled"] as? Bool ?? false,
                    volume: (value["volume"] as? NSNumber)?.floatValue ?? 0.25,
                    muted: value["muted"] as? Bool ?? false)
            }
        } else if let data = defaults.data(forKey: legacyOutputsKey) {
            migrate(from: data)
        }
        defaults.removeObject(forKey: legacyOutputsKey)
    }

    /// One-time import of the former JSON store. It saved linear gain; the slider
    /// is now perceptual (see `gain(forLevel:)`), so take the cube root to keep loudness.
    private func migrate(from data: Data) {
        struct Legacy: Decodable { let enabled: Bool; let volume: Float; let muted: Bool }
        guard let legacy = try? JSONDecoder().decode([String: Legacy].self, from: data) else { return }
        for (uid, value) in legacy {
            let gain = value.volume.isFinite ? min(1, max(0, value.volume)) : 0
            save(SoftwareOutputSettings(enabled: value.enabled, volume: cbrtf(gain), muted: value.muted), for: uid)
        }
    }
}
