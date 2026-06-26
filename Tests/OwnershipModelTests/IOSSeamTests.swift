#if canImport(UIKit)
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("iOS seam S5/L1")
@MainActor
struct IOSSeamTests {
    // DISABLED: documents a REAL bug the harness found, pending a proper fix.
    // SessionClient.handleTextFrame applies `.ownership(snapshot)` UNCONDITIONALLY
    // (no monotonic epoch guard), so a stale/reordered ownership frame rolls the
    // iOS client's view back to an older epoch. Downstream, sendOwnerResizeToServer
    // then emits ownerResize with that stale epoch, which the store rejects — the
    // iOS owner silently loses the ability to resize. This is the S5/TERM-11.x
    // "stale callback" class. The one-line fix (guard `snapshot.epoch >= current.epoch`)
    // lives in Sources/ and touches the vertical-sizing peer's active file, so it is
    // escalated to a separate reviewed change rather than smuggled into the harness.
    // Re-enable (remove .disabled) once the guard lands.
    @Test(.disabled("documents found bug GRAFT-OWN-iOS-epoch-guard; re-enable when SessionClient epoch guard lands"))
    func iosFollowerIgnoresSupersededOwnershipFrame() async throws {
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
