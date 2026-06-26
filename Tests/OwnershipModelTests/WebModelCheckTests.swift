import Testing
import GrafttyProtocol

@Suite("Web model-check sweep")
struct WebModelCheckTests {
    @Test(arguments: Array<UInt64>(1...500))
    func noInvariantViolationsAcrossSeeds(seed: UInt64) {
        let result = runScenario(seed: seed, opCount: 60)
        #expect(result.violations.isEmpty, "seed \(seed): \(result.violations)\n\(result.transcript.joined(separator: "\n"))")
    }

    // Teeth: two different grids at the SAME epoch (owner resize), delivered out of
    // emission order to a follower whose epoch guard alone would accept both. With the
    // ESN guard the stale one must be ignored; if the guard is bypassed the oracle must
    // raise S5. This proves the ESN strengthening actually catches the resize-reorder class.
    @Test func sameEpochReorderedGridIsCaughtByESN() throws {
        var world = MultiTransportWorld(session: "main")
        let web = DisplayClientID("web-1")
        world.webHandle(.hello(clientID: web, kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        world.webHandle(.takeControl(clientID: web, kind: .web, cols: 80, rows: 24))
        let g1 = world.emit()                 // emissionSeq s1, grid 80x24, epoch e
        world.webHandle(.ownerResize(clientID: web, epoch: g1.snapshot.epoch, cols: 120, rows: 24))
        let g2 = world.emit()                 // emissionSeq s2 > s1, grid 120x24, SAME epoch e
        world.webFollower.bypassEpochGuard = true   // simulate the pre-fix adapter
        world.deliverToWebFollower(g2)        // newest first
        world.deliverToWebFollower(g1)        // stale grid, lower emissionSeq
        #expect(world.oracle.violations.contains { if case .s5SupersededApplied = $0 { return true }; return false })
    }
}
