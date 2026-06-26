import Foundation
import GrafttyProtocol
@testable import GrafttyKit

/// Extends `StoreWorld`-style ownership driving with the real
/// `WebSocketBridgeCoordinator` + `WebDisplayOwnershipBroadcaster` so the
/// harness can exercise the full web-server path, not just the bare store.
///
/// The web follower (`webFollower`) is a model standing in for the TypeScript
/// client; `deliverToWebFollower` routes a tagged snapshot through it and runs
/// the S5 monotonic-guard checks (epoch regression and ESN regression).  Call
/// `checkL1` at quiescence to verify the follower converged to the store's
/// authoritative epoch, emission, and grid.
struct MultiTransportWorld {
    let session: String
    let store: SessionDisplayOwnershipStore
    var oracle: Oracle
    private(set) var webFollower: WebFollowerView
    var fakeNetwork: FakeNetwork

    private let coordinator: WebSocketBridgeCoordinator
    private let broadcaster: WebDisplayOwnershipBroadcaster

    /// The browser-side protocol client ID from the most-recent `.hello` frame.
    /// Used as the `target` field in S5/L1 violations.
    private var webClientID: DisplayClientID?

    /// Harness-side monotonic emission counter.  Incremented once per `emit()`
    /// call; NOT a store field — the store's `ownerResize` updates the grid
    /// without bumping `epoch`, so epoch alone cannot version grids.
    private(set) var emissionSeqCounter: UInt64 = 0

    init(session: String) {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let coordinator = WebSocketBridgeCoordinator(
            sessionName: session,
            clientID: DisplayClientID("server-web-harness"),
            defaultKind: .web,
            ownershipStore: store,
            broadcaster: broadcaster,
            sendText: { _ in },
            resize: { _, _ in },
            write: { _ in }
        )
        self.session = session
        self.store = store
        self.oracle = Oracle()
        self.webFollower = WebFollowerView()
        self.fakeNetwork = FakeNetwork()
        self.broadcaster = broadcaster
        self.coordinator = coordinator
        self.webClientID = nil
    }

    /// Forward a control envelope to the real coordinator.
    /// Records the browser-side client ID from `.hello` frames so violations
    /// can be attributed to the right target.
    mutating func webHandle(_ envelope: WebControlEnvelope) {
        if case let .hello(clientID, _, _, _, _, _) = envelope {
            webClientID = clientID
        }
        coordinator.handleControl(envelope)
    }

    /// Snapshot the store's current state and tag it with the next monotonic
    /// emission sequence number.  Call once after each `webHandle` that may
    /// have mutated the store.
    mutating func emit() -> TaggedSnapshot {
        emissionSeqCounter += 1
        let snapshot = store.snapshot(sessionName: session)
        return TaggedSnapshot(snapshot: snapshot, emissionSeq: emissionSeqCounter)
    }

    /// Deliver a tagged snapshot to the web follower and run the S5 checks.
    ///
    /// S5 fires when the follower actually applies a delivery that is
    /// superseded — either by epoch regression or by ESN regression (a
    /// same-epoch stale grid delivered out of emission order).  With the
    /// guards in effect both cases are silently ignored, so S5 never fires in
    /// normal (non-bypass) operation.
    mutating func deliverToWebFollower(_ tagged: TaggedSnapshot) {
        let highestEpochBefore = webFollower.highestApplied
        let highestEmissionBefore = webFollower.highestAppliedEmission
        webFollower.apply(tagged)
        let target = webClientID ?? DisplayClientID("unknown")

        // S5 by epoch regression: a lower-epoch snapshot was applied (bypass was on
        // or the guard was absent).
        if tagged.snapshot.epoch < highestEpochBefore,
           webFollower.highestApplied == tagged.snapshot.epoch {
            oracle.violations.append(.s5SupersededApplied(
                target: target,
                applied: tagged.snapshot.epoch,
                highest: highestEpochBefore
            ))
        }

        // S5 by ESN regression: a lower-emission snapshot was applied despite a
        // higher-emission one having been applied already.  This catches
        // same-epoch grid reordering (e.g. ownerResize delivered out of order).
        if tagged.emissionSeq < highestEmissionBefore,
           webFollower.highestAppliedEmission == tagged.emissionSeq {
            oracle.violations.append(.s5SupersededApplied(
                target: target,
                applied: tagged.snapshot.epoch,
                highest: highestEpochBefore
            ))
        }
    }

    /// Check L1 convergence at quiescence.
    ///
    /// The follower's `highestApplied` must equal the store's current epoch,
    /// `highestAppliedEmission` must equal the latest emission this world
    /// produced, and the follower's grid must match the store's grid.
    mutating func checkL1() {
        guard emissionSeqCounter > 0, let target = webClientID else { return }
        let storeSnapshot = store.snapshot(sessionName: session)
        let epochOK = webFollower.highestApplied == storeSnapshot.epoch
        let emissionOK = webFollower.highestAppliedEmission == emissionSeqCounter
        let gridOK = webFollower.grid == storeSnapshot.grid
        if !epochOK || !emissionOK || !gridOK {
            oracle.violations.append(.l1Divergence(target: target))
        }
    }
}
