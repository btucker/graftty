import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("Web seam S5/L1")
struct WebSeamTests {
    @Test func delayedLowerEmissionSnapshotNeverAppliedOverNewer() throws {
        var world = MultiTransportWorld(session: "main")
        let web = DisplayClientID("web-1")
        world.webHandle(.hello(clientID: web, kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        world.webHandle(.takeControl(clientID: web, kind: .web, cols: 80, rows: 24))   // epoch e1
        let g1 = world.emit()   // emissionSeq s1, epoch e1
        world.webHandle(.ownerResize(clientID: web, epoch: g1.snapshot.epoch, cols: 100, rows: 24)) // grid changes, epoch stays e1
        let g2 = world.emit()   // emissionSeq s2 > s1, epoch e1 (same)
        // Deliver the newer snapshot first, then the stale one:
        world.deliverToWebFollower(g2)
        world.deliverToWebFollower(g1)   // ESN guard rejects this (s1 < s2)
        #expect(!world.oracle.violations.contains { if case .s5SupersededApplied = $0 { true } else { false } })
        // Convergence (L1): follower applied g2 (the latest emission).
        #expect(world.webFollower.highestApplied == g2.snapshot.epoch)
        world.checkL1()
        #expect(!world.oracle.violations.contains { if case .l1Divergence = $0 { true } else { false } })
    }
}
