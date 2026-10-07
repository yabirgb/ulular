import XCTest
import Foundation
import AppSettings

final class AudioPreferencesTests: XCTestCase {
    private var domain: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        domain = "MusicTaskTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        super.tearDown()
    }

    func testSettingsSurviveNewInstance() {
        let preferences = AudioPreferences(defaults: defaults)
        preferences.keyboardPreferred = true
        preferences.save(SoftwareOutputSettings(enabled: true, volume: 0.42, muted: true), for: "monitor-uid")
        let reopened = AudioPreferences(defaults: UserDefaults(suiteName: domain)!)
        XCTAssertTrue(reopened.keyboardPreferred)
        XCTAssertEqual(reopened.output(for: "monitor-uid"), SoftwareOutputSettings(enabled: true, volume: 0.42, muted: true))
    }

    func testDisablingIsRememberedAndOutputsAreIndependent() {
        let preferences = AudioPreferences(defaults: defaults)
        XCTAssertTrue(preferences.keyboardPreferred)
        preferences.keyboardPreferred = false
        preferences.save(SoftwareOutputSettings(enabled: true, volume: 0.3), for: "first")
        preferences.save(SoftwareOutputSettings(enabled: false, volume: 0.6), for: "second")
        let reopened = AudioPreferences(defaults: defaults)
        XCTAssertFalse(reopened.keyboardPreferred)
        XCTAssertTrue(reopened.output(for: "first").enabled)
        XCTAssertFalse(reopened.output(for: "second").enabled)
        XCTAssertFalse(reopened.output(for: "unknown").enabled)
    }

    func testLegacyJSONIsMigratedPreservingLoudness() throws {
        let legacy = #"{"monitor":{"enabled":true,"volume":0.125,"muted":true}}"#
        defaults.set(Data(legacy.utf8), forKey: "softwareOutputSettings")
        let migrated = AudioPreferences(defaults: defaults).output(for: "monitor")
        XCTAssertTrue(migrated.enabled)
        XCTAssertTrue(migrated.muted)
        // Old linear gain 0.125 becomes slider level 0.5, which maps back to the same gain.
        XCTAssertEqual(migrated.volume, 0.5, accuracy: 0.0001)
        XCTAssertNil(defaults.object(forKey: "softwareOutputSettings"))
        XCTAssertEqual(AudioPreferences(defaults: defaults).output(for: "monitor"), migrated)
    }

    func testStoredDoubleVolumeIsRead() {
        defaults.set(["monitor": ["enabled": true, "volume": 0.3, "muted": false]], forKey: "softwareOutputs")
        XCTAssertEqual(AudioPreferences(defaults: defaults).output(for: "monitor").volume, 0.3, accuracy: 0.0001)
    }

    func testPerceptualGainCurve() {
        XCTAssertEqual(SoftwareOutputSettings.gain(forLevel: 0), 0)
        XCTAssertEqual(SoftwareOutputSettings.gain(forLevel: 1), 1)
        XCTAssertEqual(SoftwareOutputSettings.gain(forLevel: 0.5), 0.125, accuracy: 0.0001)
        XCTAssertEqual(SoftwareOutputSettings.gain(forLevel: .nan), 0)
        XCTAssertEqual(SoftwareOutputSettings(volume: 1, muted: true).gain, 0)
    }

    func testInvalidVolumeIsClamped() {
        XCTAssertEqual(SoftwareOutputSettings(volume: 10).volume, 1)
        XCTAssertEqual(SoftwareOutputSettings(volume: -1).volume, 0)
        XCTAssertEqual(SoftwareOutputSettings(volume: .nan).volume, 0.25)
    }
}
