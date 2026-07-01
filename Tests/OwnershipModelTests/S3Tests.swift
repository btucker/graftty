import Testing
import GrafttyProtocol
@testable import GrafttyKit

/// S3 — an accepted `ownerResize` must carry an epoch matching the store's
/// current epoch.  The corpus generates owner resizes (including deliberately
/// stale epoch-0 ones), so the S3 check must actually run against real
/// acceptance results, not the placeholder `lastResize: nil`.
@Suite("S3 stale-resize teeth")
struct S3Tests {
    /// Teeth: the oracle must flag an accepted resize whose requested epoch does
    /// not match the store's current epoch — the exact accepted-stale-resize the
    /// store must never produce.
    @Test func oracleCatchesAcceptedStaleResize() {
        var world = MultiTransportWorld(session: "main")
        let web = DisplayClientID("web-1")
        world.webHandle(.hello(clientID: web, kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        world.webHandle(.takeControl(clientID: web, kind: .web, cols: 80, rows: 24))
        let snap = world.emit().snapshot

        let staleAccepted = SessionDisplayOwnershipResizeResult(accepted: true, snapshot: snap)
        world.oracle.checkAfterEvent(
            store: world.store,
            session: "main",
            lastResize: staleAccepted,
            requestedEpoch: snap.epoch &+ 1   // mismatched epoch on an accepted resize
        )
        #expect(world.oracle.violations.contains { if case .s3StaleResizeAccepted = $0 { return true }; return false })
    }

    /// Non-vacuity: at least one corpus seed must feed an accepted owner resize to
    /// the S3 check.  If this is always zero, S3 has no corpus teeth — a store
    /// regression that accepted a stale resize would slip every seed.
    @Test func s3CheckIsNonVacuousAcrossCorpus() {
        var total = 0
        for seed: UInt64 in 1...100 {
            total += runScenario(seed: seed, opCount: 60).s3CheckCount
            if total > 0 { break }
        }
        #expect(total > 0, "No seed fed an accepted ownerResize to the S3 check — S3 has no corpus teeth")
    }
}
