#if canImport(UIKit)
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("iOS seam S5/L1")
@MainActor
struct IOSSeamTests {
    // Verifies the fix for a bug this harness found: SessionClient.handleTextFrame
    // once applied `.ownership(snapshot)` unconditionally (no monotonic epoch guard),
    // so a stale/reordered ownership frame rolled the iOS view back to an older epoch —
    // and the subsequent ownerResize, carrying that stale epoch, was rejected by the
    // store, silently stripping the iOS owner's ability to resize (S5/TERM-11.x class).
    // The guard (`snapshot.epoch < last.epoch → discard`) landed in main via #225.
    // NOTE: this suite is `#if canImport(UIKit)` — it runs on the iOS CI job, not the
    // macOS gate, since it drives the real (UIKit-only) SessionClient follower.
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
