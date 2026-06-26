import Testing
import GrafttyProtocol

/// Re-catches the "ignore stale WebSocket ownership callbacks" regression using
/// the real oracle invariants.
///
/// The pre-fix TypeScript adapter applied every incoming ownership frame
/// unconditionally — no monotonic guard.  A delivery that arrived out of order
/// (lower emission sequence than a frame already applied) would silently
/// overwrite a newer grid.  `bypassEpochGuard = true` on `WebFollowerView`
/// simulates that adapter; S5 must fire to prove the harness has teeth.
@Suite("Historical regression re-catch")
struct HistoricalRegressionTests {
    /// @spec ownership-model: When a web follower with a bypassed epoch guard
    /// receives a snapshot whose emission sequence is lower than one already
    /// applied, the oracle shall raise s5SupersededApplied for that delivery.
    @Test func s5CatchesStaleWebsocketCallback() {
        var world = MultiTransportWorld(session: "main")
        world.webFollower.bypassEpochGuard = true        // simulate the pre-fix adapter
        let web = DisplayClientID("web-1")
        world.webHandle(.hello(clientID: web, kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        world.webHandle(.takeControl(clientID: web, kind: .web, cols: 80, rows: 24))
        let e1 = world.emit()                            // emissionSeq 1, grid 80×24
        world.webHandle(.ownerResize(clientID: web, epoch: e1.snapshot.epoch, cols: 100, rows: 24))
        let e2 = world.emit()                            // emissionSeq 2, same epoch, grid 100×24
        world.deliverToWebFollower(e2)                   // newest first
        world.deliverToWebFollower(e1)                   // stale (lower ESN), applied because guard is bypassed
        #expect(world.oracle.violations.contains(.s5SupersededApplied(
            target: web,
            applied: e1.snapshot.epoch,
            highest: e2.snapshot.epoch
        )))
    }
}
