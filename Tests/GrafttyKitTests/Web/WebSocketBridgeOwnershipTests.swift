import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

@Suite("WebSocket bridge ownership gate")
struct WebSocketBridgeOwnershipTests {
    private let sessionName = "main"

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var resizes: [DisplayGrid] = []
        private(set) var writes: [Data] = []
        private(set) var sent: [WebControlEnvelope] = []

        func resize(cols: UInt16, rows: UInt16) {
            lock.lock()
            resizes.append(try! DisplayGrid(cols: cols, rows: rows))
            lock.unlock()
        }

        func write(_ data: Data) {
            lock.lock()
            writes.append(data)
            lock.unlock()
        }

        func send(_ payload: String) {
            lock.lock()
            if let envelope = try? WebControlEnvelope.parse(Data(payload.utf8)) {
                sent.append(envelope)
            }
            lock.unlock()
        }

        func snapshot() -> (resizes: [DisplayGrid], writes: [Data], sent: [WebControlEnvelope]) {
            lock.lock()
            defer { lock.unlock() }
            return (resizes, writes, sent)
        }
    }

    @Test
    func ownerResizeReachesWebSessionResize() throws {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let owner = makeCoordinator(
            store: store,
            broadcaster: broadcaster,
            serverClientID: DisplayClientID("server-web-1")
        )

        owner.coordinator.handleControl(.hello(
            clientID: DisplayClientID("browser-generated-1"),
            kind: .web,
            role: .interactive,
            visible: true,
            cols: 80,
            rows: 24
        ))
        let snapshot = store.snapshot(sessionName: sessionName)

        owner.coordinator.handleControl(.ownerResize(
            clientID: DisplayClientID("browser-generated-1"),
            epoch: snapshot.epoch,
            cols: 100,
            rows: 30
        ))

        #expect(owner.recorder.snapshot().resizes == [try DisplayGrid(cols: 100, rows: 30)])
        #expect(store.snapshot(sessionName: sessionName).grid == (try DisplayGrid(cols: 100, rows: 30)))
    }

    @Test
    func followerResizeIsRejected() throws {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let owner = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-1"))
        let follower = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-2"))

        owner.coordinator.handleControl(.hello(clientID: DisplayClientID("owner-protocol"), kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        follower.coordinator.handleControl(.hello(clientID: DisplayClientID("follower-protocol"), kind: .web, role: .interactive, visible: true, cols: 90, rows: 25))
        let epoch = store.snapshot(sessionName: sessionName).epoch

        follower.coordinator.handleControl(.ownerResize(
            clientID: DisplayClientID("follower-protocol"),
            epoch: epoch,
            cols: 120,
            rows: 40
        ))

        #expect(follower.recorder.snapshot().resizes.isEmpty)
        #expect(store.snapshot(sessionName: sessionName).grid == (try DisplayGrid(cols: 80, rows: 24)))
    }

    @Test
    func ownerBinaryInputReachesWebSessionWrite() {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let owner = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-1"))

        owner.coordinator.handleControl(.hello(clientID: DisplayClientID("owner-protocol"), kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        owner.coordinator.handleBinary(Data("echo owner\n".utf8))

        #expect(owner.recorder.snapshot().writes == [Data("echo owner\n".utf8)])
    }

    @Test
    func followerBinaryInputIsIgnored() {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let owner = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-1"))
        let follower = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-2"))

        owner.coordinator.handleControl(.hello(clientID: DisplayClientID("owner-protocol"), kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        follower.coordinator.handleControl(.hello(clientID: DisplayClientID("follower-protocol"), kind: .web, role: .interactive, visible: true, cols: 90, rows: 25))
        follower.coordinator.handleBinary(Data("echo follower\n".utf8))

        #expect(follower.recorder.snapshot().writes.isEmpty)
    }

    @Test
    func takeoverImmediatelyResizesPTYToNewOwnerGrid() throws {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let owner = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-1"))
        let takeover = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-ios-1"))

        owner.coordinator.handleControl(.hello(clientID: DisplayClientID("owner-protocol"), kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        takeover.coordinator.handleControl(.hello(clientID: DisplayClientID("ios-protocol"), kind: .ios, role: .interactive, visible: true, cols: 90, rows: 25))

        takeover.coordinator.handleControl(.takeControl(
            clientID: DisplayClientID("ios-protocol"),
            kind: .ios,
            cols: 120,
            rows: 40
        ))

        #expect(takeover.recorder.snapshot().resizes == [try DisplayGrid(cols: 120, rows: 40)])
        let snapshot = store.snapshot(sessionName: sessionName)
        #expect(snapshot.ownerClientID == DisplayClientID("server-ios-1"))
        #expect(snapshot.ownerKind == .ios)
        #expect(snapshot.grid == (try DisplayGrid(cols: 120, rows: 40)))
    }

    @Test
    func ownerDisconnectEmitsOwnerlessSnapshotAndDoesNotAutoPromoteFollower() throws {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let owner = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-1"))
        let follower = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-2"))

        owner.coordinator.handleControl(.hello(clientID: DisplayClientID("owner-protocol"), kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        follower.coordinator.handleControl(.hello(clientID: DisplayClientID("follower-protocol"), kind: .web, role: .interactive, visible: true, cols: 90, rows: 25))
        let epoch = store.snapshot(sessionName: sessionName).epoch
        owner.coordinator.handleControl(.ownerResize(clientID: DisplayClientID("owner-protocol"), epoch: epoch, cols: 100, rows: 30))

        owner.coordinator.detach()

        let snapshot = store.snapshot(sessionName: sessionName)
        #expect(snapshot.isOwnerless)
        #expect(snapshot.grid == (try DisplayGrid(cols: 100, rows: 30)))

        let ownerships = follower.recorder.snapshot().sent.compactMap { envelope -> DisplayOwnershipSnapshot? in
            guard case let .ownership(snapshot) = envelope else { return nil }
            return snapshot
        }
        let last = try #require(ownerships.last)
        #expect(last.isOwnerless)
        #expect(last.grid == (try DisplayGrid(cols: 100, rows: 30)))
        #expect(last.epoch == 2)
    }

    @Test
    func legacyResizeClaimsOwnerlessConnectionButDoesNotOverrideExistingOwner() throws {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let legacy = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-1"))
        let follower = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-2"))

        legacy.coordinator.handleControl(.resize(cols: 90, rows: 28))
        #expect(legacy.recorder.snapshot().resizes == [try DisplayGrid(cols: 90, rows: 28)])
        #expect(store.snapshot(sessionName: sessionName).ownerClientID == DisplayClientID("server-web-1"))

        follower.coordinator.handleControl(.resize(cols: 120, rows: 40))
        #expect(follower.recorder.snapshot().resizes.isEmpty)
        #expect(store.snapshot(sessionName: sessionName).grid == (try DisplayGrid(cols: 90, rows: 28)))
    }

    @Test
    func invalidPTYSizePollIsIgnored() {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let owner = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-1"))

        owner.coordinator.handlePTYSize(cols: 0, rows: 0)

        #expect(owner.recorder.snapshot().sent.isEmpty)
    }

    private func makeCoordinator(
        store: SessionDisplayOwnershipStore,
        broadcaster: WebDisplayOwnershipBroadcaster,
        serverClientID: DisplayClientID
    ) -> (coordinator: WebSocketBridgeCoordinator, recorder: Recorder) {
        let recorder = Recorder()
        let coordinator = WebSocketBridgeCoordinator(
            sessionName: sessionName,
            clientID: serverClientID,
            defaultKind: .web,
            ownershipStore: store,
            broadcaster: broadcaster,
            sendText: { recorder.send($0) },
            resize: { cols, rows in recorder.resize(cols: cols, rows: rows) },
            write: { recorder.write($0) }
        )
        return (coordinator, recorder)
    }
}
