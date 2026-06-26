import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("Web seam S5/L1")
struct WebSeamTests {
    @Test func delayedLowerEpochSnapshotNeverAppliedOverNewer() throws {
        var world = MultiTransportWorld(session: "main")
        let web = DisplayClientID("web-1")
        world.webHandle(.hello(clientID: web, kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        world.webHandle(.takeControl(clientID: web, kind: .web, cols: 80, rows: 24))   // epoch e1
        let e1Snapshot = world.store.snapshot(sessionName: "main")
        world.webHandle(.ownerResize(clientID: web, epoch: e1Snapshot.epoch, cols: 100, rows: 24)) // grid changes, epoch stays the same
        let newer = world.store.snapshot(sessionName: "main")
        // Deliver the stale e1 snapshot to the follower AFTER newer:
        world.deliverToWebFollower(newer)
        world.deliverToWebFollower(e1Snapshot)
        #expect(world.oracle.violations.contains(.s5SupersededApplied(target: web, applied: e1Snapshot.epoch, highest: newer.epoch)) == false)
        // Convergence (L1): the follower's applied epoch equals the store's.
        #expect(world.webFollower.highestApplied == newer.epoch)
        world.checkL1()
        #expect(!world.oracle.violations.contains { if case .l1Divergence = $0 { true } else { false } })
    }
}
