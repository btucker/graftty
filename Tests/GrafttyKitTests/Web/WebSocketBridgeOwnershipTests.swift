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

        func ownershipSnapshots() -> [DisplayOwnershipSnapshot] {
            snapshot().sent.compactMap { envelope in
                guard case let .ownership(snapshot) = envelope else { return nil }
                return snapshot
            }
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
        owner.coordinator.handleControl(.takeControl(
            clientID: DisplayClientID("browser-generated-1"),
            kind: .web,
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

        #expect(owner.recorder.snapshot().resizes == [
            try DisplayGrid(cols: 80, rows: 24),
            try DisplayGrid(cols: 100, rows: 30),
        ])
        #expect(store.snapshot(sessionName: sessionName).grid == (try DisplayGrid(cols: 100, rows: 30)))
    }

    @Test
    func ownerReceivesLocalizedOwnershipSnapshotUsingProtocolClientID() throws {
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
        owner.coordinator.handleControl(.takeControl(
            clientID: DisplayClientID("browser-generated-1"),
            kind: .web,
            cols: 80,
            rows: 24
        ))

        #expect(store.snapshot(sessionName: sessionName).ownerClientID == DisplayClientID("server-web-1"))
        let ownership = try #require(owner.recorder.ownershipSnapshots().last)
        #expect(ownership.ownerClientID == DisplayClientID("browser-generated-1"))
        #expect(ownership.ownerKind == .web)
    }

    @Test
    func requestDefaultKindWinsOverSpoofedFrameKind() throws {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let socket = makeCoordinator(
            store: store,
            broadcaster: broadcaster,
            serverClientID: DisplayClientID("server-ios-1"),
            defaultKind: .ios
        )

        socket.coordinator.handleControl(.hello(
            clientID: DisplayClientID("ios-protocol"),
            kind: .web,
            role: .interactive,
            visible: true,
            cols: 90,
            rows: 25
        ))
        socket.coordinator.handleControl(.takeControl(
            clientID: DisplayClientID("ios-protocol"),
            kind: .web,
            cols: 120,
            rows: 40
        ))

        let snapshot = store.snapshot(sessionName: sessionName)
        #expect(snapshot.ownerClientID == DisplayClientID("server-ios-1"))
        #expect(snapshot.ownerKind == .ios)
        let ownership = try #require(socket.recorder.ownershipSnapshots().last)
        #expect(ownership.ownerKind == .ios)
    }

    @Test("""
    @spec IOS-4.25: On an ownerless session, an iOS WebSocket `hello` shall attach the client and return an ownerless ownership snapshot rather than implicitly claiming ownership. This is the transport-level state that lets GrafttyMobile show Take Control before sending the explicit `takeControl` frame.
    """)
    func iosHelloReturnsOwnerlessSnapshotUntilExplicitTakeControl() throws {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let socket = makeCoordinator(
            store: store,
            broadcaster: broadcaster,
            serverClientID: DisplayClientID("server-ios-1"),
            defaultKind: .ios
        )

        socket.coordinator.handleControl(.hello(
            clientID: DisplayClientID("ios-protocol"),
            kind: .ios,
            role: .interactive,
            visible: true,
            cols: 90,
            rows: 25
        ))

        let snapshot = store.snapshot(sessionName: sessionName)
        #expect(snapshot.isOwnerless)
        let ownership = try #require(socket.recorder.ownershipSnapshots().last)
        #expect(ownership.isOwnerless)
    }

    @Test
    func followerResizeIsRejected() throws {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let owner = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-1"))
        let follower = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-2"))

        owner.coordinator.handleControl(.hello(clientID: DisplayClientID("owner-protocol"), kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        owner.coordinator.handleControl(.takeControl(clientID: DisplayClientID("owner-protocol"), kind: .web, cols: 80, rows: 24))
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
        owner.coordinator.handleControl(.takeControl(clientID: DisplayClientID("owner-protocol"), kind: .web, cols: 80, rows: 24))
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
        owner.coordinator.handleControl(.takeControl(clientID: DisplayClientID("owner-protocol"), kind: .web, cols: 80, rows: 24))
        follower.coordinator.handleControl(.hello(clientID: DisplayClientID("follower-protocol"), kind: .web, role: .interactive, visible: true, cols: 90, rows: 25))
        follower.coordinator.handleBinary(Data("echo follower\n".utf8))

        #expect(follower.recorder.snapshot().writes.isEmpty)
    }

    @Test
    func binaryBeforeTakeControlDoesNotClaimOwnerlessSocketOrWrite() {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let legacy = makeCoordinator(
            store: store,
            broadcaster: broadcaster,
            serverClientID: DisplayClientID("server-ios-1"),
            defaultKind: .ios
        )

        legacy.coordinator.handleBinary(Data("first key".utf8))

        #expect(legacy.recorder.snapshot().writes.isEmpty)
        let snapshot = store.snapshot(sessionName: sessionName)
        #expect(snapshot.isOwnerless)
    }

    @Test
    func binaryBeforeTakeControlDoesNotRaceImplicitOwnership() {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let racing = makeCoordinator(
            store: store,
            broadcaster: broadcaster,
            serverClientID: DisplayClientID("server-ios-1"),
            defaultKind: .ios
        )

        racing.coordinator.handleBinary(Data("racing key".utf8))

        #expect(racing.recorder.snapshot().writes.isEmpty)
        let snapshot = store.snapshot(sessionName: sessionName)
        #expect(snapshot.isOwnerless)
    }

    @Test
    func takeoverImmediatelyResizesPTYToNewOwnerGrid() throws {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let owner = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-1"))
        let takeover = makeCoordinator(
            store: store,
            broadcaster: broadcaster,
            serverClientID: DisplayClientID("server-ios-1"),
            defaultKind: .ios
        )

        owner.coordinator.handleControl(.hello(clientID: DisplayClientID("owner-protocol"), kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        owner.coordinator.handleControl(.takeControl(clientID: DisplayClientID("owner-protocol"), kind: .web, cols: 80, rows: 24))
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
        owner.coordinator.handleControl(.takeControl(clientID: DisplayClientID("owner-protocol"), kind: .web, cols: 80, rows: 24))
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
    func legacyResizeWithoutTakeControlDoesNotClaimOrResize() throws {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let legacy = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-1"))
        let follower = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-2"))

        legacy.coordinator.handleControl(.resize(cols: 90, rows: 28))
        #expect(legacy.recorder.snapshot().resizes.isEmpty)
        #expect(store.snapshot(sessionName: sessionName).isOwnerless)

        follower.coordinator.handleControl(.resize(cols: 120, rows: 40))
        #expect(follower.recorder.snapshot().resizes.isEmpty)
        #expect(store.snapshot(sessionName: sessionName).isOwnerless)
    }

    @Test
    func invalidPTYSizePollIsIgnored() {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let owner = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-1"))

        owner.coordinator.handlePTYSize(cols: 0, rows: 0)

        #expect(owner.recorder.snapshot().sent.isEmpty)
    }

    @Test("""
    @spec WEB-3.7: The web/iOS bridge shall propagate ownership mutations that originate from any transport — including the Mac host mutating the shared SessionDisplayOwnershipStore directly — to every connected WebSocket client, so a follower learns when the Mac takes or releases the display.
    """)
    func macHostTakeoverReachesWebClient() throws {
        let store = SessionDisplayOwnershipStore()
        // Constructed with the store, exactly as WebServer.Config does, so the
        // broadcaster re-broadcasts store mutations made outside this bridge.
        let broadcaster = WebDisplayOwnershipBroadcaster(store: store)
        let web = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-1"))

        // Web client attaches and explicitly claims the ownerless session.
        web.coordinator.handleControl(.hello(clientID: DisplayClientID("web-protocol"), kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        web.coordinator.handleControl(.takeControl(clientID: DisplayClientID("web-protocol"), kind: .web, cols: 80, rows: 24))
        #expect(store.snapshot(sessionName: sessionName).ownerKind == .web)

        // The Mac host takes over by mutating the shared store directly — the
        // way HostManagedZmxOwnership does — without passing through this bridge.
        _ = store.attachClient(
            sessionName: sessionName,
            clientID: DisplayClientID("mac-1"),
            kind: .mac,
            role: .interactive,
            visible: true,
            grid: try DisplayGrid(cols: 120, rows: 40)
        )
        let claim = store.claimOwner(
            sessionName: sessionName,
            clientID: DisplayClientID("mac-1"),
            kind: .mac,
            grid: try DisplayGrid(cols: 120, rows: 40)
        )
        #expect(claim.accepted)

        // The web client must have been told the Mac now owns the display.
        let last = try #require(web.recorder.ownershipSnapshots().last)
        #expect(last.ownerKind == .mac)
        #expect(last.grid == (try DisplayGrid(cols: 120, rows: 40)))
    }

    private func makeCoordinator(
        store: SessionDisplayOwnershipStore,
        broadcaster: WebDisplayOwnershipBroadcaster,
        serverClientID: DisplayClientID,
        defaultKind: DisplayClientKind = .web
    ) -> (coordinator: WebSocketBridgeCoordinator, recorder: Recorder) {
        let recorder = Recorder()
        let coordinator = WebSocketBridgeCoordinator(
            sessionName: sessionName,
            clientID: serverClientID,
            defaultKind: defaultKind,
            ownershipStore: store,
            broadcaster: broadcaster,
            sendText: { recorder.send($0) },
            resize: { cols, rows in recorder.resize(cols: cols, rows: rows) },
            write: { recorder.write($0) }
        )
        return (coordinator, recorder)
    }
}
