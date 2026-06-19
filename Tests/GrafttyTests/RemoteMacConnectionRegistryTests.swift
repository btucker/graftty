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

    @Test("successful connect posts offer to last known base URL and applies answer")
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

    @Test("connect reuses in-flight and active connection for one remote identity")
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

    private func makeRegistry(
        signalingTransport: @escaping SignalingClient.Transport,
        connectionFactory: @escaping RemoteMacConnectionRegistry.HostConnectionFactory = { _, _ in
            FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        }
    ) -> RemoteMacConnectionRegistry {
        RemoteMacConnectionRegistry(
            identityProvider: {
                try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x41, count: 32))
            },
            clientDeviceID: RemoteDeviceID(value: "client-mac"),
            signalingClient: SignalingClient(transport: signalingTransport),
            connectionFactory: connectionFactory,
            paneEnvironmentBuilder: { remoteHost, onSnapshot in
                await RemoteMacPaneEnvironment.build(
                    remoteHost: remoteHost,
                    onSnapshot: onSnapshot
                )
            }
        )
    }
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

private actor FakeRemoteMacHostConnection: RemoteMacHostConnection {
    private let offerSDP: String
    private let offerGate: OfferGate?
    private var createOfferCalls = 0
    private var appliedAnswerStorage: [String] = []
    private var openedTerminalSessionStorage: [String] = []

    init(offerSDP: String, offerGate: OfferGate? = nil) {
        self.offerSDP = offerSDP
        self.offerGate = offerGate
    }

    var createOfferCallCount: Int { createOfferCalls }
    var appliedAnswers: [String] { appliedAnswerStorage }
    var openedTerminalSessions: [String] { openedTerminalSessionStorage }

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
        FakePanesStateDriver()
    }

    func makePaneControlDriver() async throws -> any PaneControlChannelDriver {
        FakePaneControlDriver()
    }

    func openTerminalSession(sessionName: String) async throws -> any WebSocketClient & Sendable {
        openedTerminalSessionStorage.append(sessionName)
        return FakeWebSocketClient()
    }

    func close() async {}
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
