import Testing
import Foundation
@testable import GrafttyKit

@Suite("UpdaterController state")
@MainActor
struct UpdaterControllerStateTests {

    @Test func startsWithNoUpdate() {
        let c = UpdaterController.forTesting()
        #expect(c.availableVersion == nil)
    }

    @Test func scheduledDiscoveryMakesBadgeVisible() {
        let c = UpdaterController.forTesting()
        c.notifyPendingUpdateDiscovered(version: "0.3.0")
        #expect(c.availableVersion == "0.3.0")
    }

    @Test func clearResetsState() {
        let c = UpdaterController.forTesting()
        c.notifyPendingUpdateDiscovered(version: "0.3.0")
        c.notifyPendingUpdateCleared()
        #expect(c.availableVersion == nil)
    }

    @Test func secondScheduledDiscoveryReplacesVersion() {
        let c = UpdaterController.forTesting()
        c.notifyPendingUpdateDiscovered(version: "0.3.0")
        c.notifyPendingUpdateDiscovered(version: "0.3.1")
        #expect(c.availableVersion == "0.3.1")
    }

    @Test("""
    @spec UPDATE-3.3: When the user enables "Receive pre-release updates" in General Settings, the application shall persist the subscription and allow Sparkle's `prerelease` channel in addition to its always-available default channel; disabling the setting shall remove only the prerelease channel.
    """)
    func prereleaseSubscriptionPersistsAndControlsAllowedChannels() throws {
        let suiteName = "UpdaterControllerStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = UpdaterController.forTesting(userDefaults: defaults)
        #expect(!controller.prereleaseUpdatesEnabled)
        #expect(controller.allowedUpdateChannels.isEmpty)

        controller.prereleaseUpdatesEnabled = true
        #expect(controller.allowedUpdateChannels == [UpdaterController.prereleaseChannel])

        let reloaded = UpdaterController.forTesting(userDefaults: defaults)
        #expect(reloaded.prereleaseUpdatesEnabled)
        reloaded.prereleaseUpdatesEnabled = false
        #expect(reloaded.allowedUpdateChannels.isEmpty)
    }
}
