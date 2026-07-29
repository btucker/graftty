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
    application shall complete the authenticated route race and signed WebRTC \
    offer/answer exchange, apply the answer, and open the remote pane-state and \
    pane-control environment.
    """)
    func successfulConnectPostsOfferAndAppliesAnswer() async throws {
        let hostKey = Curve25519.Signing.PrivateKey()
        let hostPublicKey = try RemoteIdentityPublicKey(
            rawRepresentation: hostKey.publicKey.rawRepresentation
        )
        let route = RemoteConnectionRoute(
            kind: .lan,
            baseURL: URL(string: "http://studio.local:8800")!
        )
        let refreshedRoute = RemoteConnectionRoute(
            kind: .tailscaleDNS,
            baseURL: URL(string: "http://studio.tailnet.ts.net:8800")!
        )
        let remote = RemoteMac(
            id: RemoteDeviceID(value: "studio-mac"),
            label: "Studio Mac",
            fingerprint: RemoteIdentityFingerprint(of: hostPublicKey),
            lastKnownBaseURL: route.baseURL,
            routes: [route]
        )
        let pinned = PinnedHost(
            id: remote.id,
            kind: .mac,
            publicKey: hostPublicKey,
            displayName: remote.label,
            pinnedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pairingURL: route.baseURL.appendingPathComponent("v2/pairing"),
            routes: [route]
        )
        let connection = FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        let captured = CapturedSignalingRequest()
        let updatedPin = CapturedPinnedHost()
        let registry = makeRegistry(
            signalingTransport: { request, body in
                captured.record(request: request, body: body)
                switch request.url?.path {
                case "/v2/rtc/challenge":
                    let probe = try JSONDecoder.iso8601().decode(
                        SignalingChallengeRequest.self,
                        from: body
                    )
                    let challenge = try SignalingChallengeResponse(
                        hostDeviceID: remote.id,
                        clientDeviceID: probe.clientDeviceID,
                        clientNonce: probe.clientNonce,
                        hostNonce: Data(repeating: 0x72, count: 32),
                        expiresAt: Date(
                            timeIntervalSince1970:
                                floor(Date().timeIntervalSince1970) + 30
                        ),
                        routes: [route, refreshedRoute],
                        signingKey: hostKey
                    )
                    return try authenticatedSignalingResponse(
                        url: request.url!,
                        value: challenge
                    )
                case "/v2/rtc/offer":
                    let offer = try JSONDecoder.iso8601().decode(
                        AuthenticatedSignalingOffer.self,
                        from: body
                    )
                    let answer = try AuthenticatedSignalingAnswer(
                        offer: offer,
                        sdp: "v=0\nanswer\n",
                        routes: [route, refreshedRoute],
                        signingKey: hostKey
                    )
                    return try authenticatedSignalingResponse(
                        url: request.url!,
                        value: answer
                    )
                default:
                    throw URLError(.unsupportedURL)
                }
            },
            pinnedHostProvider: { _ in pinned },
            pinnedHostUpdater: { updatedPin.record($0) },
            connectionFactory: { _, _ in connection }
        )

        let entry = try await registry.connect(to: remote)

        #expect(entry.identity == RemoteMacIdentity(remote))
        #expect(captured.url == URL(string: "http://studio.local:8800/v2/rtc/offer"))
        let offerBody = try #require(captured.body)
        let offer = try JSONDecoder.iso8601().decode(
            AuthenticatedSignalingOffer.self,
            from: offerBody
        )
        #expect(offer.clientDeviceID == RemoteDeviceID(value: "client-mac"))
        #expect(offer.sdp == "v=0\noffer\n")
        #expect(await connection.appliedAnswers == ["v=0\nanswer\n"])
        #expect(entry.paneEnvironment.worktreePanesStore != nil)
        #expect(entry.paneEnvironment.paneControlClient != nil)
        #expect(updatedPin.value?.routes == [route, refreshedRoute])
        #expect(updatedPin.value?.lastSuccessfulRoute == route)
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
                try signalingResponse(url: request.url!, answer: TestSignalingAnswer(sdp: "v=0\nanswer\n"))
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
                try signalingResponse(url: request.url!, answer: TestSignalingAnswer(sdp: "v=0\nanswer\n"))
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
                try signalingResponse(url: request.url!, answer: TestSignalingAnswer(sdp: "v=0\nanswer\n"))
            },
            connectionFactory: { _, _ in connection },
            paneEnvironmentBuilder: { _, _, _ in .empty }
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
                    answer: TestSignalingAnswer(sdp: "v=0\nanswer\n")
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
                    answer: TestSignalingAnswer(sdp: "v=0\nanswer\n")
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

    @Test("panes-state closure evicts the live entry and publishes failure")
    func panesStateClosureEvictsLiveEntry() async throws {
        let closeEmitter = RemoteMacPaneCloseEmitter()
        let connection = FakeRemoteMacHostConnection(
            offerSDP: "v=0\noffer\n",
            paneCloseEmitter: closeEmitter
        )
        let stateRecorder = RemoteMacConnectionStateRecorder()
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(
                    url: request.url!,
                    answer: TestSignalingAnswer(sdp: "v=0\nanswer\n")
                )
            },
            connectionFactory: { _, _ in connection }
        )
        registry.onConnectionStateChange = { identity, state in
            stateRecorder.record(identity: identity, state: state)
        }
        let remote = try makeRemoteMac()
        let identity = RemoteMacIdentity(remote)
        _ = try await registry.connect(to: remote)

        await closeEmitter.emit("relay-ended")
        for _ in 0..<20 where registry.activeConnectionCount != 0 {
            await Task.yield()
        }
        for _ in 0..<20 {
            if await connection.closeCount == 1 { break }
            await Task.yield()
        }

        #expect(registry.activeConnectionCount == 0)
        let states = stateRecorder.states
        #expect(states.count == 1)
        #expect(states.first?.0 == identity)
        #expect(
            states.first?.1 == .failed(
                reason: "panes-state channel closed: relay-ended"
            )
        )
        #expect(await connection.closeCount == 1)
    }

    @Test("panes-state closure during setup cannot activate an entry")
    func panesStateClosureDuringSetupFailsConnection() async throws {
        let connection = FakeRemoteMacHostConnection(
            offerSDP: "v=0\noffer\n",
            closePanesDuringDriverCreationReason: "closed-during-open"
        )
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(
                    url: request.url!,
                    answer: TestSignalingAnswer(sdp: "v=0\nanswer\n")
                )
            },
            connectionFactory: { _, _ in connection }
        )
        let remote = try makeRemoteMac()

        await #expect(throws: (any Error).self) {
            _ = try await registry.connect(to: remote)
        }

        #expect(registry.activeConnectionCount == 0)
        #expect(await connection.closeCount == 1)
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
                    answer: TestSignalingAnswer(sdp: "v=0\nanswer\n")
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
                    answer: TestSignalingAnswer(sdp: "v=0\nanswer\n")
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
        pinnedHostProvider: RemoteMacConnectionRegistry.PinnedHostProvider? = nil,
        pinnedHostUpdater: RemoteMacConnectionRegistry.PinnedHostUpdater? = nil,
        connectionFactory: @escaping RemoteMacConnectionRegistry.HostConnectionFactory = { _, _ in
            FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        },
        paneEnvironmentBuilder: @escaping RemoteMacConnectionRegistry.PaneEnvironmentBuilder = { remoteHost, onSnapshot, onClosed in
            await RemoteMacPaneEnvironment.build(
                remoteHost: remoteHost,
                onSnapshot: onSnapshot,
                onClosed: onClosed
            )
        },
        onPaneSnapshot: @escaping RemoteMacConnectionRegistry.PaneSnapshotHandler = { _, _ in }
    ) -> RemoteMacConnectionRegistry {
        let defaultHostKey = try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x62, count: 32)
        )
        let defaultHostPublicKey = try! RemoteIdentityPublicKey(
            rawRepresentation: defaultHostKey.publicKey.rawRepresentation
        )
        let defaultRoute = RemoteConnectionRoute(
            kind: .lan,
            baseURL: URL(string: "http://studio.local:9443")!
        )
        let effectivePinnedHostProvider = pinnedHostProvider ?? { id in
            PinnedHost(
                id: id,
                kind: .mac,
                publicKey: defaultHostPublicKey,
                displayName: "Studio Mac",
                pinnedAt: Date(timeIntervalSince1970: 1_700_000_000),
                pairingURL: defaultRoute.baseURL.appendingPathComponent("v2/pairing"),
                routes: [defaultRoute]
            )
        }
        let effectiveTransport: SignalingClient.Transport
        if pinnedHostProvider != nil {
            effectiveTransport = signalingTransport
        } else {
            effectiveTransport = { request, body in
                switch request.url?.path {
                case "/v2/rtc/challenge":
                    let probe = try JSONDecoder.iso8601().decode(
                        SignalingChallengeRequest.self,
                        from: body
                    )
                    let challenge = try SignalingChallengeResponse(
                        hostDeviceID: RemoteDeviceID(value: "studio-mac"),
                        clientDeviceID: probe.clientDeviceID,
                        clientNonce: probe.clientNonce,
                        hostNonce: Data(repeating: 0x63, count: 32),
                        expiresAt: Date(
                            timeIntervalSince1970:
                                floor(Date().timeIntervalSince1970) + 30
                        ),
                        routes: [defaultRoute],
                        signingKey: defaultHostKey
                    )
                    return try authenticatedSignalingResponse(
                        url: request.url!,
                        value: challenge
                    )
                case "/v2/rtc/offer":
                    let legacyResponse = try await signalingTransport(request, body)
                    let legacyAnswer = try JSONDecoder().decode(
                        TestSignalingAnswer.self,
                        from: legacyResponse.0
                    )
                    let offer = try JSONDecoder.iso8601().decode(
                        AuthenticatedSignalingOffer.self,
                        from: body
                    )
                    let answer = try AuthenticatedSignalingAnswer(
                        offer: offer,
                        sdp: legacyAnswer.sdp,
                        routes: [defaultRoute],
                        signingKey: defaultHostKey
                    )
                    return try authenticatedSignalingResponse(
                        url: request.url!,
                        value: answer
                    )
                default:
                    throw URLError(.unsupportedURL)
                }
            }
        }
        return RemoteMacConnectionRegistry(
            identityProvider: {
                try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x41, count: 32))
            },
            clientDeviceID: RemoteDeviceID(value: "client-mac"),
            pinnedHostProvider: effectivePinnedHostProvider,
            pinnedHostUpdater: pinnedHostUpdater,
            signalingClient: SignalingClient(transport: effectiveTransport),
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

private struct TestSignalingAnswer: Codable {
    let sdp: String
}

private func signalingResponse(url: URL, answer: TestSignalingAnswer) throws -> (Data, HTTPURLResponse) {
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

private func authenticatedSignalingResponse<Value: Encodable>(
    url: URL,
    value: Value
) throws -> (Data, HTTPURLResponse) {
    (
        try JSONEncoder.iso8601().encode(value),
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

private final class CapturedPinnedHost: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: PinnedHost?

    var value: PinnedHost? {
        lock.withLock { storage }
    }

    func record(_ host: PinnedHost) {
        lock.withLock {
            storage = host
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

private actor RemoteMacPaneCloseEmitter {
    private var onClosed: (@Sendable (String) async -> Void)?

    func install(_ onClosed: @escaping @Sendable (String) async -> Void) {
        self.onClosed = onClosed
    }

    func emit(_ reason: String) async {
        await onClosed?(reason)
    }
}

private final class RemoteMacConnectionStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage:
        [(RemoteMacIdentity, RemoteHostConnection.State)] = []

    var states: [(RemoteMacIdentity, RemoteHostConnection.State)] {
        lock.withLock { storage }
    }

    func record(
        identity: RemoteMacIdentity,
        state: RemoteHostConnection.State
    ) {
        lock.withLock { storage.append((identity, state)) }
    }
}

private actor FakeRemoteMacHostConnection: RemoteMacHostConnection {
    private let offerSDP: String
    private let offerGate: OfferGate?
    private let snapshotEmitter: RemoteMacSnapshotEmitter?
    private let paneCloseEmitter: RemoteMacPaneCloseEmitter?
    private let closePanesDuringDriverCreationReason: String?
    private var createOfferCalls = 0
    private var appliedAnswerStorage: [String] = []
    private var openedTerminalSessionStorage: [String] = []
    private var closeCallCount = 0
    private var state: RemoteHostConnection.State = .connected
    private var stateHandler: (@Sendable (RemoteHostConnection.State) -> Void)?

    init(
        offerSDP: String,
        offerGate: OfferGate? = nil,
        snapshotEmitter: RemoteMacSnapshotEmitter? = nil,
        paneCloseEmitter: RemoteMacPaneCloseEmitter? = nil,
        closePanesDuringDriverCreationReason: String? = nil
    ) {
        self.offerSDP = offerSDP
        self.offerGate = offerGate
        self.snapshotEmitter = snapshotEmitter
        self.paneCloseEmitter = paneCloseEmitter
        self.closePanesDuringDriverCreationReason =
            closePanesDuringDriverCreationReason
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
        await paneCloseEmitter?.install(onClosed)
        if let closePanesDuringDriverCreationReason {
            await onClosed(closePanesDuringDriverCreationReason)
        }
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
