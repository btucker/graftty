import CryptoKit
import Foundation
import GrafttyProtocol
import Testing

@testable import GrafttyRemoteClient

@Suite("RemoteHostDialer signed negotiation")
struct RemoteHostDialerTests {
    @Test("negotiate checkpoints after each network step and stamps the pin only after applying the answer")
    func negotiateAppliesAnswerThenRefreshesPin() async throws {
        let fixture = try DialerFixture()
        let events = EventLog()
        let link = ScriptedWebRTCLink(events: events)
        let transport = fixture.transport()
        let connectedAt = Date(timeIntervalSince1970: 1_800_000_100)

        let refreshed = try await RemoteHostDialer.negotiate(
            link,
            signaling: SignalingClient(transport: { request, body in
                events.append("signal \(request.url?.path ?? "")")
                return try await transport(request, body)
            }),
            pinnedHost: fixture.pinnedHost,
            routes: [fixture.lanRoute],
            clientKey: fixture.clientKey,
            clientDeviceID: fixture.clientDeviceID,
            replacingExistingConnection: false,
            connectedAt: {
                events.append("now")
                return connectedAt
            },
            checkpoint: { events.append("checkpoint") }
        )

        #expect(await link.appliedAnswers == ["v=0\nanswer\n"])
        #expect(events.values == [
            "offer", "checkpoint",
            "signal /v2/rtc/challenge", "signal /v2/rtc/offer", "checkpoint",
            "apply", "checkpoint",
            "now",
        ])
        #expect(refreshed.routes == [fixture.lanRoute, fixture.tailRoute])
        #expect(refreshed.lastSuccessfulRoute == fixture.lanRoute)
        #expect(refreshed.lastConnectedAt == connectedAt)
        #expect(refreshed.publicKey == fixture.pinnedHost.publicKey)
    }

    @Test("a checkpoint that throws after the offer stops before any signaling request")
    func throwingCheckpointStopsBeforeSignaling() async throws {
        let fixture = try DialerFixture()
        let events = EventLog()
        let link = ScriptedWebRTCLink(events: events)

        await #expect(throws: CancellationError.self) {
            _ = try await RemoteHostDialer.negotiate(
                link,
                signaling: SignalingClient(transport: { request, _ in
                    events.append("signal \(request.url?.path ?? "")")
                    throw URLError(.cannotConnectToHost)
                }),
                pinnedHost: fixture.pinnedHost,
                routes: [fixture.lanRoute],
                clientKey: fixture.clientKey,
                clientDeviceID: fixture.clientDeviceID,
                replacingExistingConnection: false,
                connectedAt: { Date() },
                checkpoint: {
                    events.append("checkpoint")
                    throw CancellationError()
                }
            )
        }

        #expect(events.values == ["offer", "checkpoint"])
        #expect(await link.appliedAnswers.isEmpty)
    }

    @Test("persistRefreshedPin rethrows a revoked pin without reporting it")
    func persistRethrowsRevokedPin() throws {
        let fixture = try DialerFixture()
        let reported = EventLog()

        #expect(throws: PinnedHostStore.Error.notFound) {
            try RemoteHostDialer.persistRefreshedPin(
                fixture.pinnedHost,
                using: { _ in throw PinnedHostStore.Error.notFound },
                onFailure: { reported.append(String(describing: $0)) }
            )
        }
        #expect(reported.values.isEmpty)
    }

    @Test("persistRefreshedPin reports other store failures without failing the connection")
    func persistReportsOtherFailures() throws {
        let fixture = try DialerFixture()
        let reported = EventLog()

        try RemoteHostDialer.persistRefreshedPin(
            fixture.pinnedHost,
            using: { _ in throw CocoaError(.fileWriteNoPermission) },
            onFailure: { reported.append(String(describing: $0)) }
        )

        #expect(reported.values.count == 1)
    }
}

private struct DialerFixture {
    let hostKey = Curve25519.Signing.PrivateKey()
    let clientKey = Curve25519.Signing.PrivateKey()
    let hostDeviceID = RemoteDeviceID(value: "dialer-host")
    let clientDeviceID = RemoteDeviceID(value: "dialer-client")
    let lanRoute = RemoteConnectionRoute(kind: .lan, baseURL: URL(string: "http://studio.local:8800")!)
    let tailRoute = RemoteConnectionRoute(
        kind: .tailscaleDNS,
        baseURL: URL(string: "http://studio.tailnet.ts.net:8800")!
    )
    let pinnedHost: PinnedHost

    init() throws {
        let hostPublicKey = try RemoteIdentityPublicKey(rawRepresentation: hostKey.publicKey.rawRepresentation)
        pinnedHost = PinnedHost(
            id: hostDeviceID,
            kind: .mac,
            publicKey: hostPublicKey,
            displayName: "Studio",
            pinnedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pairingURL: lanRoute.baseURL.appendingPathComponent("v2/pairing"),
            routes: [lanRoute]
        )
    }

    /// Answers the challenge and offer as a correctly signing host would.
    func transport() -> SignalingClient.Transport {
        let hostKey = hostKey
        let hostDeviceID = hostDeviceID
        let routes = [lanRoute, tailRoute]
        return { request, body in
            switch request.url?.path {
            case "/\(RemoteAccessProtocol.challengePath)":
                let probe = try JSONDecoder.iso8601().decode(SignalingChallengeRequest.self, from: body)
                let challenge = try SignalingChallengeResponse(
                    hostDeviceID: hostDeviceID,
                    clientDeviceID: probe.clientDeviceID,
                    clientNonce: probe.clientNonce,
                    hostNonce: Data(repeating: 0x5A, count: 32),
                    // Whole seconds: the ISO 8601 wire form drops fractions,
                    // which would invalidate the signature after decoding.
                    expiresAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 30),
                    routes: routes,
                    signingKey: hostKey
                )
                return try Self.okResponse(request, challenge)
            case "/\(RemoteAccessProtocol.offerPath)":
                let offer = try JSONDecoder.iso8601().decode(AuthenticatedSignalingOffer.self, from: body)
                let answer = try AuthenticatedSignalingAnswer(
                    offer: offer,
                    sdp: "v=0\nanswer\n",
                    routes: routes,
                    signingKey: hostKey
                )
                return try Self.okResponse(request, answer)
            default:
                throw URLError(.unsupportedURL)
            }
        }
    }

    private static func okResponse<Value: Encodable>(
        _ request: URLRequest,
        _ value: Value
    ) throws -> (Data, HTTPURLResponse) {
        (
            try JSONEncoder.iso8601().encode(value),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        )
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private struct LinkUnused: Error {}

/// Answers only the SDP steps; every channel is unused by negotiation.
private actor ScriptedWebRTCLink: WebRTCHostLink {
    private let events: EventLog?
    private(set) var appliedAnswers: [String] = []

    init(events: EventLog? = nil) {
        self.events = events
    }

    var state: RemoteHostConnectionState { .connected }
    func setOnStateChange(_ handler: (@Sendable (RemoteHostConnectionState) -> Void)?) {}
    func createOfferSDP() -> String {
        events?.append("offer")
        return "v=0\noffer\n"
    }
    func applyAnswerSDP(_ sdp: String) {
        events?.append("apply")
        appliedAnswers.append(sdp)
    }
    func makePanesStateDriver(originAware: Bool) throws -> any PanesStateSubscriptionDriver { throw LinkUnused() }
    func makePaneControlDriver() throws -> any PaneControlChannelDriver { throw LinkUnused() }
    func makeWorktreeManagementDriver() throws -> any WorktreeManagementChannelDriver { throw LinkUnused() }
    func makeTeamClient(
        handler: @escaping TeamRPCSession.Handler,
        onClose: @escaping @Sendable () async -> Void
    ) throws -> TeamChannelClient { throw LinkUnused() }
    func openTerminalClient(sessionName: String, preferPaged: Bool) throws -> any WebSocketClient & Sendable {
        throw LinkUnused()
    }
    func forwardLocalPort(host: String, port: Int) throws -> LocalPortForward { throw LinkUnused() }
    func close() {}
}
