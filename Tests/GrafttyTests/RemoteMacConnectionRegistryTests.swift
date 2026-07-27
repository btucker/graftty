import CryptoKit
import Foundation
import GrafttyProtocol
import GrafttyRemoteClient
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("RemoteMacConnectionRegistry")
@MainActor
struct RemoteMacConnectionRegistryTests {
    @Test("missing base URL fails closed")
    func missingBaseURLFailsClosed() async throws {
        let registry = makeRegistry(signalingTransport: { request, _ in
            Issue.record("Signaling should not be called for \(request)")
            throw URLError(.badURL)
        })
        let remote = try makeRemoteMac(baseURL: nil)

        await #expect(throws: RemoteMacConnectionRegistry.ConnectionError.missingBaseURL(RemoteMacIdentity(remote))) {
            _ = try await registry.connect(to: remote)
        }
        #expect(registry.activeConnectionCount == 0)
    }

    @Test("""
    @spec REMOTE-12.5: When the user connects to a saved Remote Mac, the \
    application shall exchange a WebRTC offer at its last known LAN base URL, \
    apply the answer, and open the remote pane-state/control environment.
    """)
    func successfulConnectPostsOfferAndAppliesAnswer() async throws {
        let connection = FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        let captured = CapturedSignalingRequest()
        let registry = makeRegistry(
            signalingTransport: { request, body in
                captured.record(request: request, body: body)
                return try signalingResponse(
                    url: request.url!,
                    answer: SignalingAnswer(sdp: "v=0\nanswer\n")
                )
            },
            connectionFactory: { _, _ in connection }
        )
        let remote = try makeRemoteMac(baseURL: URL(string: "http://studio.local:9443")!)

        let entry = try await registry.connect(to: remote)

        #expect(entry.identity == RemoteMacIdentity(remote))
        #expect(captured.url == URL(string: "http://studio.local:9443/v1/rtc/offer"))
        let offerBody = try #require(captured.body)
        let offer = try JSONDecoder().decode(SignalingOffer.self, from: offerBody)
        #expect(offer.clientDeviceID == "client-mac")
        #expect(offer.sdp == "v=0\noffer\n")
        #expect(await connection.appliedAnswers == ["v=0\nanswer\n"])
        #expect(entry.paneEnvironment.worktreePanesStore != nil)
        #expect(entry.paneEnvironment.paneControlClient != nil)
    }

    @Test("""
    @spec REMOTE-12.6: While connection setup or a live connection already \
    exists for a Remote Mac identity, repeated connect requests shall reuse \
    that one connection rather than dial another transport.
    """)
    func connectReusesInflightAndActiveConnection() async throws {
        let gate = OfferGate()
        let connection = FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n", offerGate: gate)
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(url: request.url!, answer: SignalingAnswer(sdp: "v=0\nanswer\n"))
            },
            connectionFactory: { _, _ in connection }
        )
        let remote = try makeRemoteMac()

        let first = Task { try await registry.connect(to: remote) }
        await gate.waitUntilOfferStarted()
        let second = Task { try await registry.connect(to: remote) }
        await Task.yield()
        #expect(await connection.createOfferCallCount == 1)

        await gate.releaseOffer()
        let firstEntry = try await first.value
        let secondEntry = try await second.value
        let activeEntry = try await registry.connect(to: remote)

        #expect(firstEntry.id == secondEntry.id)
        #expect(activeEntry.id == firstEntry.id)
        #expect(await connection.createOfferCallCount == 1)
        #expect(registry.activeConnectionCount == 1)
    }

    @Test("entry opens terminal sessions on demand")
    func entryOpensTerminalSessionsOnDemand() async throws {
        let connection = FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(url: request.url!, answer: SignalingAnswer(sdp: "v=0\nanswer\n"))
            },
            connectionFactory: { _, _ in connection }
        )
        let entry = try await registry.connect(to: try makeRemoteMac())

        _ = try await entry.openTerminalSession(sessionName: "main")

        #expect(await connection.openedTerminalSessions == ["main"])
    }

    @Test("empty pane environment fails connection and closes transport")
    func emptyPaneEnvironmentFailsConnectionAndClosesTransport() async throws {
        let connection = FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        let remote = try makeRemoteMac()
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(url: request.url!, answer: SignalingAnswer(sdp: "v=0\nanswer\n"))
            },
            connectionFactory: { _, _ in connection },
            paneEnvironmentBuilder: { _, _ in .empty }
        )

        await #expect(throws: RemoteMacConnectionRegistry.ConnectionError.paneEnvironmentUnavailable(RemoteMacIdentity(remote))) {
            _ = try await registry.connect(to: remote)
        }

        #expect(await connection.closeCount == 1)
        #expect(registry.activeConnectionCount == 0)
    }

    @Test("signaling failure closes the allocated transport")
    func signalingFailureClosesAllocatedTransport() async throws {
        let connection = FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        let registry = makeRegistry(
            signalingTransport: { _, _ in
                throw URLError(.cannotConnectToHost)
            },
            connectionFactory: { _, _ in connection }
        )

        await #expect(throws: (any Error).self) {
            _ = try await registry.connect(to: makeRemoteMac())
        }

        #expect(await connection.closeCount == 1)
        #expect(registry.activeConnectionCount == 0)
    }

    @Test("disconnect rejects and closes a cancellation-insensitive late success")
    func disconnectRejectsLateSuccess() async throws {
        let gate = OfferGate()
        let connection = FakeRemoteMacHostConnection(
            offerSDP: "v=0\noffer\n",
            offerGate: gate
        )
        let remote = try makeRemoteMac()
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(
                    url: request.url!,
                    answer: SignalingAnswer(sdp: "v=0\nanswer\n")
                )
            },
            connectionFactory: { _, _ in connection }
        )

        let connectTask = Task { try await registry.connect(to: remote) }
        await gate.waitUntilOfferStarted()
        registry.disconnect(identity: RemoteMacIdentity(remote))
        await gate.releaseOffer()

        await #expect(throws: CancellationError.self) {
            _ = try await connectTask.value
        }
        #expect(await connection.closeCount == 1)
        #expect(registry.activeConnectionCount == 0)
    }

    @Test("terminal connection state evicts only the matching live entry")
    func terminalStateEvictsLiveEntry() async throws {
        let connection = FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(
                    url: request.url!,
                    answer: SignalingAnswer(sdp: "v=0\nanswer\n")
                )
            },
            connectionFactory: { _, _ in connection }
        )
        let remote = try makeRemoteMac()
        _ = try await registry.connect(to: remote)
        #expect(registry.activeConnectionCount == 1)

        await connection.transition(to: .failed(reason: "ICE failed"))
        for _ in 0..<20 where registry.activeConnectionCount != 0 {
            await Task.yield()
        }

        #expect(registry.activeConnectionCount == 0)
        await #expect(throws: RemoteMacConnectionRegistry.ConnectionError.notConnected(RemoteMacIdentity(remote))) {
            _ = try await registry.openTerminalSession(
                identity: RemoteMacIdentity(remote),
                sessionName: "main"
            )
        }
    }

    @Test("""
    @spec REMOTE-12.12: If a cached Remote Mac connection is already in a \
    terminal state when connect is requested, the registry shall evict and \
    close it before dialing a fresh transport.
    """)
    func cachedTerminalConnectionIsRedialed() async throws {
        let first = FakeRemoteMacHostConnection(offerSDP: "v=0\nfirst\n")
        let second = FakeRemoteMacHostConnection(offerSDP: "v=0\nsecond\n")
        let sequence = RemoteMacConnectionSequence([first, second])
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(
                    url: request.url!,
                    answer: SignalingAnswer(sdp: "v=0\nanswer\n")
                )
            },
            connectionFactory: { _, _ in sequence.next() }
        )
        let remote = try makeRemoteMac()

        let firstEntry = try await registry.connect(to: remote)
        await first.setStateWithoutNotification(.closed)
        let secondEntry = try await registry.connect(to: remote)

        #expect(secondEntry.id != firstEntry.id)
        #expect(await first.closeCount == 1)
        #expect(await second.createOfferCallCount == 1)
    }

    @Test("""
    @spec REMOTE-12.13: When an obsolete Remote Mac pane subscription emits \
    after disconnect or replacement, the registry shall discard that snapshot \
    instead of overwriting the current sidebar projection.
    """)
    func stalePaneSnapshotAfterDisconnectIsDiscarded() async throws {
        let emitter = RemoteMacSnapshotEmitter()
        let recorder = RemoteMacSnapshotRecorder()
        let connection = FakeRemoteMacHostConnection(
            offerSDP: "v=0\noffer\n",
            snapshotEmitter: emitter
        )
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(
                    url: request.url!,
                    answer: SignalingAnswer(sdp: "v=0\nanswer\n")
                )
            },
            connectionFactory: { _, _ in connection },
            onPaneSnapshot: { identity, snapshot in
                recorder.record(identity: identity, snapshot: snapshot)
            }
        )
        let remote = try makeRemoteMac()
        let identity = RemoteMacIdentity(remote)
        _ = try await registry.connect(to: remote)
        let liveSnapshot = [makeWorktreeSnapshot(path: "/live")]
        await emitter.emit(liveSnapshot)

        registry.disconnect(identity: identity)
        await emitter.emit([makeWorktreeSnapshot(path: "/stale")])

        #expect(recorder.snapshots == [liveSnapshot])
    }

    private func makeRegistry(
        signalingTransport: @escaping SignalingClient.Transport,
        connectionFactory: @escaping RemoteMacConnectionRegistry.HostConnectionFactory = { _, _ in
            FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        },
        paneEnvironmentBuilder: @escaping RemoteMacConnectionRegistry.PaneEnvironmentBuilder = { remoteHost, onSnapshot in
            await RemoteMacPaneEnvironment.build(
                remoteHost: remoteHost,
                onSnapshot: onSnapshot
            )
        },
        onPaneSnapshot: @escaping RemoteMacConnectionRegistry.PaneSnapshotHandler = { _, _ in }
    ) -> RemoteMacConnectionRegistry {
        RemoteMacConnectionRegistry(
            identityProvider: {
                try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x41, count: 32))
            },
            clientDeviceID: RemoteDeviceID(value: "client-mac"),
            signalingClient: SignalingClient(transport: signalingTransport),
            connectionFactory: connectionFactory,
            paneEnvironmentBuilder: paneEnvironmentBuilder,
            onPaneSnapshot: onPaneSnapshot
        )
    }
}

private func makeWorktreeSnapshot(path: String) -> WorktreePanes {
    WorktreePanes(
        path: path,
        displayName: URL(fileURLWithPath: path).lastPathComponent,
        repoDisplayName: "repo",
        displayBranch: "main",
        state: .running,
        isMainCheckout: true,
        prBadge: nil,
        stats: nil,
        attentionText: nil,
        layout: nil
    )
}

private func signalingResponse(url: URL, answer: SignalingAnswer) throws -> (Data, HTTPURLResponse) {
    (
        try JSONEncoder().encode(answer),
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    )
}

private func makeRemoteMac(
    id: RemoteDeviceID = RemoteDeviceID(value: "studio-mac"),
    label: String = "Studio Mac",
    fingerprintByte: UInt8 = 0x22,
    baseURL: URL? = URL(string: "http://studio.local:9443"),
    addedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> RemoteMac {
    RemoteMac(
        id: id,
        label: label,
        fingerprint: try RemoteIdentityFingerprint(rawBytes: Data(repeating: fingerprintByte, count: 32)),
        lastKnownBaseURL: baseURL,
        addedAt: addedAt
    )
}

private final class CapturedSignalingRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (url: URL?, body: Data?) = (nil, nil)

    var url: URL? { lock.withLock { storage.url } }
    var body: Data? { lock.withLock { storage.body } }

    func record(request: URLRequest, body: Data) {
        lock.withLock {
            storage = (request.url, body)
        }
    }
}

private actor OfferGate {
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWaitForRelease() async {
        started = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilOfferStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func releaseOffer() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private final class RemoteMacConnectionSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [any RemoteMacHostConnection]

    init(_ connections: [any RemoteMacHostConnection]) {
        self.connections = connections
    }

    func next() -> any RemoteMacHostConnection {
        lock.withLock { connections.removeFirst() }
    }
}

private actor RemoteMacSnapshotEmitter {
    private var onSnapshot: (@Sendable ([WorktreePanes]) async -> Void)?

    func install(_ onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void) {
        self.onSnapshot = onSnapshot
    }

    func emit(_ snapshot: [WorktreePanes]) async {
        await onSnapshot?(snapshot)
    }
}

private final class RemoteMacSnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[WorktreePanes]] = []

    var snapshots: [[WorktreePanes]] {
        lock.withLock { storage }
    }

    func record(identity _: RemoteMacIdentity, snapshot: [WorktreePanes]) {
        lock.withLock { storage.append(snapshot) }
    }
}

private actor FakeRemoteMacHostConnection: RemoteMacHostConnection {
    private let offerSDP: String
    private let offerGate: OfferGate?
    private let snapshotEmitter: RemoteMacSnapshotEmitter?
    private var createOfferCalls = 0
    private var appliedAnswerStorage: [String] = []
    private var openedTerminalSessionStorage: [String] = []
    private var closeCallCount = 0
    private var state: RemoteHostConnection.State = .connected
    private var stateHandler: (@Sendable (RemoteHostConnection.State) -> Void)?

    init(
        offerSDP: String,
        offerGate: OfferGate? = nil,
        snapshotEmitter: RemoteMacSnapshotEmitter? = nil
    ) {
        self.offerSDP = offerSDP
        self.offerGate = offerGate
        self.snapshotEmitter = snapshotEmitter
    }

    var createOfferCallCount: Int { createOfferCalls }
    var appliedAnswers: [String] { appliedAnswerStorage }
    var openedTerminalSessions: [String] { openedTerminalSessionStorage }
    var closeCount: Int { closeCallCount }

    func setOnStateChange(
        _ handler: (@Sendable (RemoteHostConnection.State) -> Void)?
    ) {
        stateHandler = handler
    }

    func currentState() -> RemoteHostConnection.State {
        state
    }

    func transition(to newState: RemoteHostConnection.State) {
        state = newState
        stateHandler?(newState)
    }

    func setStateWithoutNotification(_ newState: RemoteHostConnection.State) {
        state = newState
    }

    func createOfferSDP() async throws -> String {
        createOfferCalls += 1
        await offerGate?.markStartedAndWaitForRelease()
        return offerSDP
    }

    func applyAnswerSDP(_ sdp: String) async throws {
        appliedAnswerStorage.append(sdp)
    }

    func makePanesStateDriver(
        onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void,
        onClosed: @escaping @Sendable (String) async -> Void
    ) async throws -> any PanesStateChannelDriver {
        await snapshotEmitter?.install(onSnapshot)
        return FakePanesStateDriver()
    }

    func makePaneControlDriver() async throws -> any PaneControlChannelDriver {
        FakePaneControlDriver()
    }

    func openTerminalSession(sessionName: String) async throws -> any WebSocketClient & Sendable {
        openedTerminalSessionStorage.append(sessionName)
        return FakeWebSocketClient()
    }

    func close() async {
        closeCallCount += 1
        state = .closed
        stateHandler?(.closed)
    }
}

private final class FakePanesStateDriver: PanesStateChannelDriver, @unchecked Sendable {
    func open() async throws {}
    func close() {}
}

private final class FakePaneControlDriver: PaneControlChannelDriver, @unchecked Sendable {
    func open() async throws {}
    func close() {}
    func send(_ request: PaneControlRequest) async throws -> PaneControlResponse {
        .ok
    }
}

private final class FakeWebSocketClient: WebSocketClient, @unchecked Sendable {
    func send(_ frame: WebSocketFrame) async throws {}
    func receive() async throws -> WebSocketFrame { .binary(Data()) }
    func close() {}
}
