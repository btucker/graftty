#if canImport(UIKit)
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("iOS seam S5/L1")
@MainActor
struct IOSSeamTests {
    @Test func iosFollowerIgnoresSupersededOwnershipFrame() async throws {
        var world = MultiTransportWorld(session: "main")
        let ios = DisplayClientID("ios-1")
        await world.attachIOS(id: ios)                  // ios connects as follower (kind .ios never auto-owns)
        let e1 = world.makeOwnershipFrame(epoch: 1, cols: 80)
        let e2 = world.makeOwnershipFrame(epoch: 2, cols: 100)
        world.enqueueIOSIncoming(e2)                     // newer first
        world.enqueueIOSIncoming(e1)                     // then stale
        await world.pumpIOS()
        #expect(world.oracle.violations.contains { if case .s5SupersededApplied = $0 { return true }; return false } == false)
        #expect(world.iosAppliedEpoch == 2)              // L1: converged to newest, ignored stale
    }
}
#endif
