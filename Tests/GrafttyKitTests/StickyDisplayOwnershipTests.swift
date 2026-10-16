import GrafttyProtocol
import Testing
@testable import GrafttyKit

@Suite
struct StickyDisplayOwnershipTests {
    private let session = "sticky"
    private let grid = DisplayGrid.daemonFallback

    private func attach(_ store: SessionDisplayOwnershipStore, _ id: String,
                        identity: String?, role: DisplayClientRole = .interactive,
                        visible: Bool = true, kind: DisplayClientKind = .ios) -> DisplayOwnershipSnapshot {
        store.attachClient(sessionName: session, clientID: DisplayClientID(id), kind: kind,
                           role: role, visible: visible, grid: grid, identity: identity)
    }

    @Test("@spec OWN-1.4: When the authenticated leading device reconnects interactively, the application shall restore its leadership on the new connection without changing the retained grid or accepting traffic from the old connection.", arguments: [false, true])
    func leaderResumesAcrossConnectionReplacement(detachFirst: Bool) throws {
        let store = SessionDisplayOwnershipStore()
        _ = attach(store, "old", identity: "phone")
        let old = store.claimOwner(sessionName: session, clientID: .init("old"), kind: .ios,
                                   grid: try DisplayGrid(cols: 95, rows: 29)).snapshot
        if detachFirst { _ = store.detachClient(sessionName: session, clientID: .init("old")) }
        let resumed = attach(store, "new", identity: "phone")
        #expect(resumed.ownerClientID == .init("new"))
        #expect(resumed.grid == old.grid)
        #expect(resumed.epoch > old.epoch)
        _ = store.detachClient(sessionName: session, clientID: .init("old"))
        #expect(store.snapshot(sessionName: session).ownerClientID == .init("new"))
        #expect(!store.ownerResize(sessionName: session, clientID: .init("old"), epoch: old.epoch, grid: grid).accepted)
        #expect(store.ownerResize(sessionName: session, clientID: .init("new"), epoch: resumed.epoch, grid: grid).accepted)
    }

    @Test("@spec OWN-1.5: While leadership is retained for a disconnected device, the application shall reject takeover by preview or hidden attachments until an eligible interactive client attaches.")
    func passiveClientsCannotResumeLeader() {
        let store = SessionDisplayOwnershipStore()
        _ = attach(store, "old", identity: "phone")
        _ = store.claimOwner(sessionName: session, clientID: .init("old"), kind: .ios, grid: grid)
        _ = store.detachClient(sessionName: session, clientID: .init("old"))
        #expect(attach(store, "preview", identity: "phone", role: .preview).ownerClientID == .init("old"))
        #expect(attach(store, "hidden", identity: "phone", visible: false).ownerClientID == .init("old"))
        #expect(attach(store, "mac", identity: nil, kind: .mac).ownerClientID == .init("mac"))
        #expect(attach(store, "other", identity: "other").ownerClientID == .init("mac"))
        #expect(store.claimOwnerIfOwnerlessOrCurrent(sessionName: session, clientID: .init("mac"), kind: .mac, grid: grid).accepted)
        #expect(!store.ownerResize(sessionName: session, clientID: .init("old"), epoch: 1, grid: grid).accepted)
    }

    @Test("@spec OWN-1.6: When another device takes control during a leader's disconnection, the application shall reconnect the former leader as a follower.")
    func newerLeaderSupersedesRetainedIdentity() {
        let store = SessionDisplayOwnershipStore()
        _ = attach(store, "old", identity: "phone")
        _ = store.claimOwner(sessionName: session, clientID: .init("old"), kind: .ios, grid: grid)
        _ = store.detachClient(sessionName: session, clientID: .init("old"))
        _ = attach(store, "other", identity: "tablet")
        let claim = store.claimOwner(sessionName: session, clientID: .init("other"), kind: .ios, grid: grid)
        let reconnected = attach(store, "new", identity: "phone")
        #expect(reconnected.ownerClientID == .init("other"))
        #expect(reconnected.epoch == claim.snapshot.epoch)
    }

    @Test(arguments: [false, true])
    func failedTakeoverRestoresDisconnectedLeader(reconnectDuringClaim: Bool) {
        let store = SessionDisplayOwnershipStore()
        _ = attach(store, "old", identity: "phone")
        let previous = store.claimOwner(sessionName: session, clientID: .init("old"), kind: .ios, grid: grid).snapshot
        _ = store.detachClient(sessionName: session, clientID: .init("old"))
        _ = attach(store, "other", identity: "tablet")
        let failed = store.claimOwner(sessionName: session, clientID: .init("other"), kind: .ios, grid: grid).snapshot
        if reconnectDuringClaim {
            _ = attach(store, "intermediate", identity: "phone")
            _ = attach(store, "new", identity: "phone")
            // Repeating an older hello must not make it the newest connection.
            _ = attach(store, "intermediate", identity: "phone")
        }
        _ = store.restoreOwnerAfterFailedClaim(sessionName: session, failedClientID: .init("other"),
            failedKind: .ios, failedEpoch: failed.epoch, previousOwnerClientID: previous.ownerClientID,
            previousOwnerKind: previous.ownerKind, previousGrid: previous.grid,
            previousOwnerIdentity: previous.ownerIdentity, previousRevision: previous.revision)
        if !reconnectDuringClaim { _ = attach(store, "new", identity: "phone") }
        #expect(store.snapshot(sessionName: session).ownerClientID == .init("new"))
    }

    @Test(arguments: [false, true])
    func rollbackDoesNotReviveSupersededConnection(retakeOnOlderConnection: Bool) {
        let store = SessionDisplayOwnershipStore()
        _ = attach(store, "superseded", identity: "phone")
        _ = store.claimOwner(sessionName: session, clientID: .init("superseded"), kind: .ios, grid: grid)
        var previous = attach(store, "leader", identity: "phone")
        if retakeOnOlderConnection {
            previous = store.claimOwner(sessionName: session, clientID: .init("superseded"), kind: .ios, grid: grid).snapshot
        } else {
            _ = store.detachClient(sessionName: session, clientID: .init("leader"))
        }
        _ = attach(store, "mac", identity: nil, kind: .mac)
        let failed = store.claimOwner(sessionName: session, clientID: .init("mac"), kind: .mac, grid: grid).snapshot
        let restored = store.restoreOwnerAfterFailedClaim(sessionName: session, failedClientID: .init("mac"),
            failedKind: .mac, failedEpoch: failed.epoch, previousOwnerClientID: previous.ownerClientID,
            previousOwnerKind: previous.ownerKind, previousGrid: previous.grid,
            previousOwnerIdentity: previous.ownerIdentity, previousRevision: previous.revision)
        #expect(restored.ownerClientID == previous.ownerClientID)
        if !retakeOnOlderConnection {
            #expect(!store.isAttachedOwner(sessionName: session, clientID: .init("superseded")))
        }
    }
}
