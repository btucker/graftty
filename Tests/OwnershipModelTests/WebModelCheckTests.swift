import Testing
import GrafttyProtocol

@Suite("Web model-check sweep")
struct WebModelCheckTests {
    // NOTE: the broad "no violations across seeds" sweep lives in `SeedCorpus`
    // (seeds 1…1000).  This suite holds only the teeth / non-vacuity tests that
    // the corpus sweep does not, to avoid re-running the same scenarios twice.

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

    // Non-vacuity: the multi-path delivery (two independent channels per follower) must
    // actually produce cross-channel reorderings that the (epoch, ESN) guard rejects.
    // If rejectCount is always zero, multi-path delivery is misconfigured and S5/L1
    // would pass vacuously — the gate wouldn't catch a guard regression.
    @Test func multiPathGuardIsNonVacuous() {
        var totalRejects = 0
        // Run seeds until the reject path is hit.  With two channels per follower and
        // random scheduling, reordering is expected within the first handful of seeds.
        for seed: UInt64 in 1...100 {
            let result = runScenario(seed: seed, opCount: 60)
            totalRejects += result.rejectCount
            if totalRejects > 0 { break }
        }
        #expect(
            totalRejects > 0,
            "No seed exercised the cross-channel S5 reject path — multi-path delivery may be misconfigured"
        )
    }

    // Non-vacuity: the L2 owner-release path must be exercised by at least one seed
    // in the corpus range.  If l2CheckCount is always zero, the L2 oracle check
    // never runs and the gate cannot catch a silent-promotion regression.
    @Test func l2PathIsNonVacuous() {
        var totalL2Checks = 0
        for seed: UInt64 in 1...100 {
            let result = runScenario(seed: seed, opCount: 60)
            totalL2Checks += result.l2CheckCount
            if totalL2Checks > 0 { break }
        }
        #expect(
            totalL2Checks > 0,
            "No seed exercised the L2 owner-release path — the L2 oracle check never ran"
        )
    }

    // L2 teeth: verify the oracle fires when the store incorrectly retains an owner
    // after a release.  Uses a stub oracle call against a world where the release is
    // not applied, so the store still has an owner when checkAfterOwnerRelease runs.
    @Test func l2OracleHasTeeth() {
        var world = MultiTransportWorld(session: "main")
        let web = DisplayClientID("web-1")
        world.webHandle(.hello(clientID: web, kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        world.webHandle(.takeControl(clientID: web, kind: .web, cols: 80, rows: 24))
        let snap = world.emit()

        // Do NOT call releaseOwner — store still has an owner.
        // checkAfterOwnerRelease should detect the silent-promotion bug.
        world.oracle.checkAfterOwnerRelease(
            store: world.store,
            session: "main",
            previousOwnerID: web,
            epochBeforeRelease: snap.snapshot.epoch
        )
        #expect(world.oracle.violations.contains { if case .l2SilentPromotion = $0 { return true }; return false })
    }
}
