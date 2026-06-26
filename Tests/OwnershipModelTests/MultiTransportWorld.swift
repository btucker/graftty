import Foundation
import GrafttyProtocol
@testable import GrafttyKit

/// Extends `StoreWorld`-style ownership driving with the real
/// `WebSocketBridgeCoordinator` + `WebDisplayOwnershipBroadcaster` so the
/// harness can exercise the full web-server path, not just the bare store.
///
/// The web follower (`webFollower`) is a model standing in for the TypeScript
/// client; `deliverToWebFollower` routes a snapshot through it and runs the
/// S5 monotonic-epoch guard check.  Call `checkL1` at quiescence to verify
/// the follower converged to the store's authoritative epoch.
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

    /// Deliver a snapshot directly to the web follower and run the S5 check.
    ///
    /// S5 fires only if the follower actually applied a snapshot whose epoch
    /// was lower than `highestApplied` (i.e. the monotonic guard was bypassed).
    /// With the guard in effect a stale delivery is silently ignored, so S5
    /// never fires in normal operation.
    mutating func deliverToWebFollower(_ snapshot: DisplayOwnershipSnapshot) {
        let highestBefore = webFollower.highestApplied
        webFollower.apply(snapshot)
        // S5: guard bypassed ⟺ lower-epoch snapshot was actually applied.
        if snapshot.epoch < highestBefore, webFollower.highestApplied == snapshot.epoch {
            let target = webClientID ?? DisplayClientID("unknown")
            oracle.violations.append(.s5SupersededApplied(
                target: target,
                applied: snapshot.epoch,
                highest: highestBefore
            ))
        }
    }

    /// Check L1 convergence at quiescence: the follower's highest applied epoch
    /// must equal the store's current authoritative epoch.
    mutating func checkL1() {
        let storeEpoch = store.snapshot(sessionName: session).epoch
        guard let target = webClientID else { return }
        if webFollower.highestApplied != storeEpoch {
            oracle.violations.append(.l1Divergence(target: target))
        }
    }
}
