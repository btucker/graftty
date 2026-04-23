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
}
