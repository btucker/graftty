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
        let broadcaster = DisplayOwnershipBroadcaster()
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
        let broadcaster = DisplayOwnershipBroadcaster()
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
        let broadcaster = DisplayOwnershipBroadcaster()
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
    @spec IOS-4.26: On an ownerless session, an iOS WebSocket `hello` shall attach the client and return an ownerless ownership snapshot rather than implicitly claiming ownership. This is the transport-level state that lets GrafttyMobile show Take Control before sending the explicit `takeControl` frame.
    """)
    func iosHelloReturnsOwnerlessSnapshotUntilExplicitTakeControl() throws {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = DisplayOwnershipBroadcaster()
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
        let broadcaster = DisplayOwnershipBroadcaster()
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
        let broadcaster = DisplayOwnershipBroadcaster()
        let owner = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-1"))

        owner.coordinator.handleControl(.hello(clientID: DisplayClientID("owner-protocol"), kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        owner.coordinator.handleControl(.takeControl(clientID: DisplayClientID("owner-protocol"), kind: .web, cols: 80, rows: 24))
        owner.coordinator.handleBinary(Data("echo owner\n".utf8))

        #expect(owner.recorder.snapshot().writes == [Data("echo owner\n".utf8)])
    }

    @Test
    func followerBinaryInputIsIgnored() {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = DisplayOwnershipBroadcaster()
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
        let broadcaster = DisplayOwnershipBroadcaster()
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
        let broadcaster = DisplayOwnershipBroadcaster()
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
        let broadcaster = DisplayOwnershipBroadcaster()
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
        let broadcaster = DisplayOwnershipBroadcaster()
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
        let broadcaster = DisplayOwnershipBroadcaster()
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
        let broadcaster = DisplayOwnershipBroadcaster()
        let owner = makeCoordinator(store: store, broadcaster: broadcaster, serverClientID: DisplayClientID("server-web-1"))

        owner.coordinator.handlePTYSize(cols: 0, rows: 0)

        #expect(owner.recorder.snapshot().sent.isEmpty)
    }

    @Test
    func ownershipSnapshotCarriesStoreRevisionNotZero() throws {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = DisplayOwnershipBroadcaster()
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

        let storeRevision = store.snapshot(sessionName: sessionName).revision
        #expect(storeRevision > 0, "the store itself must have advanced its revision by now")
        let ownership = try #require(owner.recorder.ownershipSnapshots().last)
        #expect(
            ownership.revision == storeRevision,
            "the wire snapshot must carry the store's current revision, not a localization-reset 0 — otherwise the same-epoch reorder guard (an owner resize that changes the grid without bumping epoch) can't distinguish a stale delivery from a fresh one"
        )
    }

    @Test("""
    @spec WEB-3.7: The web/iOS bridge shall propagate ownership mutations that originate from any transport — including the Mac host mutating the shared SessionDisplayOwnershipStore directly — to every connected WebSocket client, so a follower learns when the Mac takes or releases the display.
    """)
    func macHostTakeoverReachesWebClient() throws {
        let store = SessionDisplayOwnershipStore()
        // Constructed with the store, exactly as WebServer.Config does, so the
        // broadcaster re-broadcasts store mutations made outside this bridge.
        let broadcaster = DisplayOwnershipBroadcaster(store: store)
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

    /// Task 6 mixed-transport parity: two REAL `TerminalAttachCoordinator`
    /// instances sharing one REAL `SessionDisplayOwnershipStore` +
    /// `DisplayOwnershipBroadcaster`, one built with `defaultKind: .web`
    /// (exactly how `WebServer`'s `/ws` bridge constructs its coordinator)
    /// and one with `defaultKind: .ios` (exactly how
    /// `GrafttyHostAgent`'s SSH terminal path — `TerminalSessionHandler`
    /// — constructs its coordinator; see
    /// `Sources/GrafttyHostAgent/SSH/Channels/TerminalSessionHandler.swift`).
    /// Only the transport's send/resize/write plumbing is simulated, the
    /// same way every other test in this file simulates the `/ws` bridge
    /// — the coordinator, store, and broadcaster driving the arbitration
    /// are 100% production code. Proves take-control flips propagate
    /// identically across two different client kinds sharing one store,
    /// which is what "SSH and web are one engine" (W2) actually means at
    /// the ownership layer.
    ///
    /// A literal end-to-end version — a real `TerminalSessionClient`
    /// (iOS/UIKit-gated, `GrafttyMobileKit`) driving an actual SSH-over-
    /// WebRTC channel alongside a real `/ws` `WebSocketClient` in the
    /// SAME process — isn't feasible here: `GrafttyMobileKit`'s SSH
    /// client only compiles under `#if canImport(UIKit)` (iOS test
    /// target), while `GrafttyKit`'s `SessionDisplayOwnershipStore`/
    /// `TerminalAttachCoordinator`/`WebServer` transitively pull in
    /// AppKit and only compile on macOS — the same platform split that
    /// forces `SSHTerminalLoopbackTests` to maintain hand-written mirrors
    /// of these exact Mac-only types instead of importing them. Combining
    /// both real transports in one test process would mean either making
    /// `GrafttyKit` iOS-buildable (out of scope for a W2 close-out) or
    /// cross-process orchestration of a macOS test binary and an iOS
    /// Simulator process — disproportionate to what this parity check
    /// needs to prove.
    @Test("""
    @spec REMOTE-5.2: While a session terminal is served over `/ws`, the application shall route its terminal and ownership traffic through the same `SessionDisplayOwnershipStore` instance used by SSH-attached clients, so a take-control transition originating from either transport is visible identically to the other.
    """)
    func mixedTransportKindsShareOwnershipStoreAndSeeTakeControlFlips() throws {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = DisplayOwnershipBroadcaster()
        let webClient = makeCoordinator(
            store: store,
            broadcaster: broadcaster,
            serverClientID: DisplayClientID("server-web-1"),
            defaultKind: .web
        )
        let sshClient = makeCoordinator(
            store: store,
            broadcaster: broadcaster,
            serverClientID: DisplayClientID("server-ssh-1"),
            defaultKind: .ios
        )

        webClient.coordinator.handleControl(.hello(
            clientID: DisplayClientID("web-protocol"),
            kind: .web,
            role: .interactive,
            visible: true,
            cols: 80,
            rows: 24
        ))
        webClient.coordinator.handleControl(.takeControl(
            clientID: DisplayClientID("web-protocol"),
            kind: .web,
            cols: 80,
            rows: 24
        ))

        sshClient.coordinator.handleControl(.hello(
            clientID: DisplayClientID("ssh-protocol"),
            kind: .ios,
            role: .interactive,
            visible: true,
            cols: 90,
            rows: 25
        ))

        // The SSH-kind client sees the web client's ownership — never
        // itself — proving the shared store is visible cross-transport
        // from the moment it attaches.
        let sshSeesWebOwns = try #require(sshClient.recorder.ownershipSnapshots().last)
        #expect(sshSeesWebOwns.ownerClientID != DisplayClientID("ssh-protocol"))
        #expect(sshSeesWebOwns.ownerKind == .web)

        // The SSH-kind client takes control — the flip must be visible to
        // BOTH sides, not just the taker.
        sshClient.coordinator.handleControl(.takeControl(
            clientID: DisplayClientID("ssh-protocol"),
            kind: .ios,
            cols: 90,
            rows: 25
        ))

        let storeSnapshot = store.snapshot(sessionName: sessionName)
        #expect(storeSnapshot.ownerKind == .ios)

        let sshOwns = try #require(sshClient.recorder.ownershipSnapshots().last)
        #expect(sshOwns.ownerClientID == DisplayClientID("ssh-protocol"))

        let webSeesHandoff = try #require(webClient.recorder.ownershipSnapshots().last)
        #expect(webSeesHandoff.ownerClientID != DisplayClientID("web-protocol"), "the former web owner must see it lost control")
        #expect(webSeesHandoff.ownerKind == .ios)
    }

    private func makeCoordinator(
        store: SessionDisplayOwnershipStore,
        broadcaster: DisplayOwnershipBroadcaster,
        serverClientID: DisplayClientID,
        defaultKind: DisplayClientKind = .web
    ) -> (coordinator: TerminalAttachCoordinator, recorder: Recorder) {
        let recorder = Recorder()
        let coordinator = TerminalAttachCoordinator(
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
