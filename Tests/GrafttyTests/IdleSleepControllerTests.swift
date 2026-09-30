import Foundation
import Testing
@testable import Graftty

@Suite("@spec REMOTE-2.20: While the user has enabled Keep Mac awake while Graftty is running, the application shall prevent idle system sleep without preventing display sleep, restore the preference on launch, and release its assertion when disabled or the controller is destroyed; the preference shall default to off.")
struct IdleSleepControllerTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "IdleSleepControllerTests.\(UUID().uuidString)")!
    }

    @Test func optInPersistsAndReleasesExactlyOnce() {
        let defaults = defaults()
        defer { defaults.removeObject(forKey: SettingsKeys.keepMacAwake) }
        var types: [String] = []
        var released: [UInt32] = []
        var controller: IdleSleepController? = IdleSleepController(
            defaults: defaults,
            createAssertion: { types.append($0); return 42 },
            releaseAssertion: { released.append($0) }
        )
        #expect(controller?.isEnabled == false)
        #expect(types.isEmpty)
        controller?.setEnabled(true)
        controller?.setEnabled(true)
        #expect(types == ["PreventUserIdleSystemSleep"])
        #expect(defaults.bool(forKey: SettingsKeys.keepMacAwake))
        controller?.setEnabled(false)
        #expect(released == [42])
        #expect(!defaults.bool(forKey: SettingsKeys.keepMacAwake))
        controller = nil
        #expect(released == [42])
    }

    @Test func restoresPreferenceAndReleasesOnDestruction() {
        let defaults = defaults()
        defer { defaults.removeObject(forKey: SettingsKeys.keepMacAwake) }
        defaults.set(true, forKey: SettingsKeys.keepMacAwake)
        var created = 0
        var released: [UInt32] = []
        var controller: IdleSleepController? = IdleSleepController(
            defaults: defaults,
            createAssertion: { _ in created += 1; return 7 },
            releaseAssertion: { released.append($0) }
        )
        #expect(controller?.isEnabled == true)
        #expect(created == 1)
        controller = nil
        #expect(released == [7])
        #expect(defaults.bool(forKey: SettingsKeys.keepMacAwake))
    }

    @Test func failedAssertionIsVisibleAndCanBeRetried() {
        let defaults = defaults()
        defer { defaults.removeObject(forKey: SettingsKeys.keepMacAwake) }
        var succeeds = false
        var released: [UInt32] = []
        let controller = IdleSleepController(
            defaults: defaults,
            createAssertion: { _ in succeeds ? 9 : nil },
            releaseAssertion: { released.append($0) }
        )
        controller.setEnabled(true)
        #expect(controller.errorMessage != nil)
        #expect(released.isEmpty)
        succeeds = true
        controller.setEnabled(true)
        #expect(controller.errorMessage == nil)
        controller.setEnabled(false)
        #expect(released == [9])
    }
}
