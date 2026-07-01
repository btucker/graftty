import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("Store invariants S1-S4")
struct StoreInvariantTests {
    private func grid(_ c: UInt16) -> DisplayGrid { try! DisplayGrid(cols: c, rows: 24) }

    @Test(arguments: Array<UInt64>(1...200))
    func randomSequencesNeverViolateStoreInvariants(seed: UInt64) {
        var world = StoreWorld(session: "main")
        var oracle = Oracle()
        var rng = DeterministicRNG(seed: seed)
        let clients = (0..<3).map { ModelClient(id: DisplayClientID("c\($0)"), kind: .mac, role: .interactive) }
        for _ in 0..<40 {
            let op = world.randomLegalOp(clients: clients, using: &rng)
            let result = world.apply(op)
            #expect(oracle.checkAfterEvent(store: world.store, session: "main",
                                           lastResize: result.resize, requestedEpoch: result.requestedEpoch).isEmpty)
        }
    }

    @Test func staleResizeIsRejectedByStoreAndOracleAgrees() throws {
        var world = StoreWorld(session: "main")
        var oracle = Oracle()
        let c = ModelClient(id: DisplayClientID("c0"), kind: .mac, role: .interactive)
        _ = world.apply(.attach(c, visible: true, grid: grid(80)))
        _ = world.apply(.takeControl(c.id, grid: grid(80)))   // epoch advances
        let stale = world.apply(.ownerResize(c.id, believedEpoch: 0, grid: grid(120)))  // wrong epoch
        #expect(stale.resize?.accepted == false)               // store rejects; S3 holds (no violation)
        let violations = oracle.checkAfterEvent(store: world.store, session: "main",
                                                lastResize: stale.resize, requestedEpoch: stale.requestedEpoch)
        #expect(violations.isEmpty)                            // oracle agrees: no invariant broken
    }
}
