import Testing
import GrafttyProtocol

/// Multi-client contention fidelity.
///
/// The corpus generates ops across distinct web clients (`web-a/b/c`) to
/// exercise ownership handoff.  For that to be non-vacuous, each web client must
/// drive the store through its OWN coordinator with a distinct store client ID —
/// exactly as production does (one `TerminalAttachCoordinator` per WebSocket
/// connection, each `clientID = websocket-<UUID>`).  A single shared coordinator
/// would bind to the first protocol client and silently drop the rest, so owner
/// identity could never change between clients and the epoch would stop advancing.
@Suite("Multi-client web contention")
struct MultiClientTests {
    @Test func takeoverBetweenClientsChangesOwnerAndBumpsEpoch() {
        var world = MultiTransportWorld(session: "main")
        let a = DisplayClientID("web-a")
        let b = DisplayClientID("web-b")

        world.webHandle(.hello(clientID: a, kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        world.webHandle(.takeControl(clientID: a, kind: .web, cols: 80, rows: 24))
        let s1 = world.emit().snapshot

        world.webHandle(.hello(clientID: b, kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        world.webHandle(.takeControl(clientID: b, kind: .web, cols: 80, rows: 24))
        let s2 = world.emit().snapshot

        #expect(s1.ownerClientID != nil, "web-a should own the display after its takeControl")
        #expect(s2.ownerClientID != nil, "web-b should own the display after its takeControl")
        #expect(s1.ownerClientID != s2.ownerClientID,
                "ownership must hand off between distinct store clients, not collapse to one id")
        #expect(s2.epoch > s1.epoch,
                "owner change must strictly bump the epoch (S2-strict)")
    }

    @Test func secondClientHelloDoesNotDropFirstClientOwnership() {
        var world = MultiTransportWorld(session: "main")
        let a = DisplayClientID("web-a")
        let b = DisplayClientID("web-b")

        world.webHandle(.hello(clientID: a, kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        world.webHandle(.takeControl(clientID: a, kind: .web, cols: 80, rows: 24))
        let owned = world.emit().snapshot
        let aOwner = owned.ownerClientID

        // A second client merely saying hello must NOT be dropped as a
        // bind-mismatch on a shared coordinator; it attaches independently and
        // leaves web-a's ownership intact until it actively takes control.
        world.webHandle(.hello(clientID: b, kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        let afterHello = world.emit().snapshot

        #expect(afterHello.ownerClientID == aOwner,
                "a passive hello from another client must not change ownership")
    }

    /// Non-vacuity: at least one corpus seed must hand ownership from one client
    /// to a different client.  If this is always zero the corpus has regressed to
    /// a single owner identity and S2-strict / L2-promotion check nothing real.
    @Test func corpusExercisesOwnerHandoffBetweenClients() {
        var totalHandoffs = 0
        for seed: UInt64 in 1...100 {
            totalHandoffs += runScenario(seed: seed, opCount: 60).ownerHandoffCount
            if totalHandoffs > 0 { break }
        }
        #expect(
            totalHandoffs > 0,
            "No seed handed ownership between distinct clients — corpus collapsed to single-client"
        )
    }
}
