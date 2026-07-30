import CryptoKit
import Foundation
import GrafttyProtocol
import Testing

@testable import GrafttyKit

@Suite("LANRemoteAccessRouteHandler")
struct LANRemoteAccessRouteHandlerTests {

    private actor OfferRecorder {
        private(set) var offers: [AuthenticatedSignalingOffer] = []

        func record(_ offer: AuthenticatedSignalingOffer) {
            offers.append(offer)
        }
    }

    private struct SignalingFixture {
        let offer: AuthenticatedSignalingOffer
        let answer: AuthenticatedSignalingAnswer
    }

    private static func makePayload(pairingURL: URL = URL(string: "https://tailnet.example.com/v2/pairing")!) throws -> PairingPayload {
        let publicKey = try RemoteIdentityPublicKey(
            rawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        )
        return PairingPayload(
            hostDeviceID: RemoteDeviceID(value: "host-1"),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            hostPublicKeyFingerprint: RemoteIdentityFingerprint(of: publicKey),
            nonce: .generate(),
            expiry: Date(timeIntervalSince1970: 1_800_000_000),
            pairingURL: pairingURL
        )
    }

    private static func makePairingIntroduceRequest() throws -> PairingIntroduceRequest {
        PairingIntroduceRequest(
            nonce: .generate(),
            clientPublicKey: try RemoteIdentityPublicKey(
                rawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
            ),
            clientDeviceID: RemoteDeviceID(value: "client-1"),
            clientKind: .mac,
            clientDisplayName: "Client Mac"
        )
    }

    private func makeHandler(
        lanBaseURL: URL = URL(string: "http://host.local:9999")!,
        rateLimit: LANRemoteAccessRateLimit = .disabled,
        beginPairing: @escaping @Sendable (TimeInterval, URL) async -> Result<PairingPayload, PairingErrorResponse> = { _, lanBaseURL in
            do {
                return .success(try Self.makePayload(pairingURL: lanBaseURL))
            } catch {
                return .failure(PairingErrorResponse(code: .internalError, error: "\(error)"))
            }
        },
        handleSignalingChallenge: @escaping LANRemoteAccessRouteHandler.SignalingChallengeHandler = { _ in
            .failure(PairingErrorResponse(code: .authenticationFailed, error: "not exercised"))
            },
        handleSignalingOffer:
            @escaping LANRemoteAccessRouteHandler.SignalingOfferHandler = { _ in
                .invalid("not exercised")
        }
    ) -> LANRemoteAccessRouteHandler {
        LANRemoteAccessRouteHandler(
            lanBaseURLProvider: { lanBaseURL },
            rateLimit: rateLimit,
            beginPairing: beginPairing,
            handleIntroduce: { _ in
                .failure(PairingErrorResponse(code: .noActiveSession, error: "not exercised"))
            },
            handleAwaitOutcome: { _ in
                .failure(PairingErrorResponse(code: .noActiveSession, error: "not exercised"))
            },
            handleSignalingChallenge: handleSignalingChallenge,
            handleSignalingOffer: handleSignalingOffer
        )
    }

    @Test("POST /v2/pairing/begin starts pairing and returns payload")
    func beginReturnsPayload() async throws {
        let handler = makeHandler()

        let response = await handler.handle(
            method: .POST,
            path: "/v2/pairing/begin",
            body: Data()
        )

        #expect(response.status == 200)
        #expect(response.contentType.contains("application/json"))
        let payload = try JSONDecoder.iso8601().decode(PairingPayload.self, from: response.body)
        #expect(payload.nonce.bytes.isEmpty == false)
    }

    @Test("GET /v2/pairing/begin returns 405")
    func getBeginReturns405() async throws {
        let handler = makeHandler()

        let response = await handler.handle(
            method: .GET,
            path: "/v2/pairing/begin",
            body: Data()
        )

        #expect(response.status == 405)
        let error = try JSONDecoder.iso8601().decode(PairingErrorResponse.self, from: response.body)
        #expect(error.code == .wrongSessionState)
    }

    @Test("legacy web routes return 404")
    func legacyWebRoutesReturn404() async throws {
        let handler = makeHandler()

        for path in ["/repos", "/worktrees", "/sessions", "/ws", "/"] {
            let response = await handler.handle(method: .GET, path: path, body: Data())
            #expect(response.status == 404, "Expected 404 for \(path)")
            let error = try JSONDecoder.iso8601().decode(PairingErrorResponse.self, from: response.body)
            #expect(error.code == .noActiveSession)
        }
    }

    @Test("/v2/rtc/offer forwards an authenticated offer to the injected handler")
    func rtcOfferForwards() async throws {
        let fixture = try Self.makeSignalingFixture()
        let recorder = OfferRecorder()
        let handler = makeHandler(handleSignalingOffer: { offer in
            await recorder.record(offer)
            return .authenticatedSuccess(fixture.answer)
        })
        let body = try JSONEncoder.iso8601().encode(fixture.offer)

        let response = await handler.handle(
            method: .POST,
            path: "/v2/rtc/offer",
            body: body
        )

        #expect(response.status == 200)
        let answer = try JSONDecoder.iso8601().decode(
            AuthenticatedSignalingAnswer.self,
            from: response.body
        )
        #expect(answer.sdp.contains("answer"))
        let offers = await recorder.offers
        #expect(offers == [fixture.offer])
    }

    @Test("""
    @spec REMOTE-2.8: Production native connections shall reject the \
    protocol-v1 signaling route and shall use the paired identity keys on both \
    LAN and Tailscale.
    """)
    func legacyRTCOfferIsRejected() async throws {
        let handler = makeHandler()
        let response = await handler.handle(
            method: .POST,
            path: "/v1/rtc/offer",
            body: Data("{}".utf8)
        )

        #expect(response.status == 426)
        let error = try JSONDecoder.iso8601().decode(
            PairingErrorResponse.self, from: response.body)
        #expect(error.code == .unsupportedVersion)
    }

    @Test("busy pairing returns a structured JSON error")
    func busyPairingReturnsStructuredError() async throws {
        let handler = makeHandler(beginPairing: { _, _ in
            .failure(PairingErrorResponse(code: .pairingBusy, error: "pairing session already active"))
        })

        let response = await handler.handle(
            method: .POST,
            path: "/v2/pairing/begin",
            body: Data()
        )

        #expect(response.status == 409)
        let error = try JSONDecoder.iso8601().decode(PairingErrorResponse.self, from: response.body)
        #expect(error.code == .pairingBusy)
    }

    @Test("POST /v2/pairing/begin returns client-reachable LAN pairing route base")
    func beginUsesLANPairingRouteBase() async throws {
        let handler = makeHandler(lanBaseURL: URL(string: "http://host.local:9999")!)

        let response = await handler.handle(
            method: .POST,
            path: "/v2/pairing/begin",
            body: Data()
        )

        #expect(response.status == 200)
        let payload = try JSONDecoder.iso8601().decode(PairingPayload.self, from: response.body)
        #expect(payload.pairingURL == URL(string: "http://host.local:9999/v2/pairing")!)
        #expect(payload.pairingURL.host != "0.0.0.0")
        #expect(payload.pairingURL.host != "::")
        #expect(payload.pairingURL.host != "localhost")
        #expect(payload.pairingURL.scheme == "http")
        #expect(payload.pairingURL.path == "/v2/pairing")
    }

    @Test("POST /v2/pairing/begin prefers request base URL over guessed host")
    func beginUsesRequestBaseURLWhenAvailable() async throws {
        let handler = makeHandler(lanBaseURL: URL(string: "http://wrong-host.local:9999")!)

        let response = await handler.handle(
            method: .POST,
            path: "/v2/pairing/begin",
            body: Data(),
            requestBaseURL: URL(string: "http://bonjour-host.local:9443")!
        )

        #expect(response.status == 200)
        let payload = try JSONDecoder.iso8601().decode(PairingPayload.self, from: response.body)
        #expect(payload.pairingURL == URL(string: "http://bonjour-host.local:9443/v2/pairing")!)
    }

    @Test("POST /v2/pairing/begin rejects loopback LAN base URLs")
    func beginRejectsLoopbackLANBaseURLs() async throws {
        for url in [
            URL(string: "http://127.0.0.1:9999")!,
            URL(string: "http://127.0.1.1:9999")!,
            URL(string: "http://[::1]:9999")!,
        ] {
            let handler = makeHandler(lanBaseURL: url)

            let response = await handler.handle(
                method: .POST,
                path: "/v2/pairing/begin",
                body: Data()
            )

            #expect(response.status == 500, "Expected loopback URL \(url) to be rejected")
            let error = try JSONDecoder.iso8601().decode(PairingErrorResponse.self, from: response.body)
            #expect(error.code == .internalError)
        }
    }

    @Test("repeated pairing requests beyond the configured limit return structured rate-limit responses")
    func repeatedPairingRequestsAreRateLimited() async throws {
        let handler = makeHandler(rateLimit: .init(maxRequests: 1, window: 60))

        _ = await handler.handle(method: .POST, path: "/v2/pairing/begin", body: Data())
        let response = await handler.handle(method: .POST, path: "/v2/pairing/begin", body: Data())

        #expect(response.status == 429)
        let error = try JSONDecoder.iso8601().decode(PairingErrorResponse.self, from: response.body)
        #expect(error.code == .rateLimited)
    }

    @Test("repeated RTC requests beyond the configured limit return structured rate-limit responses")
    func repeatedRTCRequestsAreRateLimited() async throws {
        let handler = makeHandler(rateLimit: .init(maxRequests: 1, window: 60))
        let body = try JSONEncoder.iso8601().encode(Self.makeChallengeRequest())

        _ = await handler.handle(method: .POST, path: "/v2/rtc/challenge", body: body)
        let response = await handler.handle(method: .POST, path: "/v2/rtc/challenge", body: body)

        #expect(response.status == 429)
        let error = try JSONDecoder.iso8601().decode(PairingErrorResponse.self, from: response.body)
        #expect(error.code == .rateLimited)
    }

    @Test("rate limiting is bucketed by route category")
    func rateLimitingIsBucketedByRouteCategory() async throws {
        let handler = makeHandler(rateLimit: .init(maxRequests: 1, window: 60))
        let body = try JSONEncoder.iso8601().encode(Self.makeChallengeRequest())

        let beginResponse = await handler.handle(method: .POST, path: "/v2/pairing/begin", body: Data())
        let rtcResponse = await handler.handle(method: .POST, path: "/v2/rtc/challenge", body: body)
        let secondRTCResponse = await handler.handle(method: .POST, path: "/v2/rtc/challenge", body: body)

        #expect(beginResponse.status == 200)
        #expect(rtcResponse.status != 429)
        #expect(secondRTCResponse.status == 429)
    }

    @Test("""
    @spec REMOTE-12.10: While unauthenticated LAN pairing and signaling \
    routes are rate limited, one source address exhausting its allowance \
    shall not consume another source address's allowance.
    """)
    func rateLimitingIsPerSource() async {
        let handler = makeHandler(rateLimit: .init(maxRequests: 1, window: 60))

        let firstA = await handler.handle(
            method: .POST,
            path: "/v2/pairing/begin",
            body: Data(),
            source: "192.168.1.10"
        )
        let secondA = await handler.handle(
            method: .POST,
            path: "/v2/pairing/begin",
            body: Data(),
            source: "192.168.1.10"
        )
        let firstB = await handler.handle(
            method: .POST,
            path: "/v2/pairing/begin",
            body: Data(),
            source: "192.168.1.11"
        )

        #expect(firstA.status == 200)
        #expect(secondA.status == 429)
        #expect(firstB.status == 200)
    }

    @Test("pairing ceremony rate limiting is bucketed by route")
    func pairingCeremonyRateLimitingIsBucketedByRoute() async throws {
        let handler = makeHandler(rateLimit: .init(maxRequests: 1, window: 60))
        let introduceBody = try JSONEncoder.iso8601().encode(Self.makePairingIntroduceRequest())
        let awaitBody = try JSONEncoder.iso8601().encode(PairingAwaitOutcomeRequest(nonce: .generate()))

        let introduceResponse = await handler.handle(
            method: .POST,
            path: "/v2/pairing/introduce",
            body: introduceBody
        )
        let awaitResponse = await handler.handle(
            method: .POST,
            path: "/v2/pairing/await-outcome",
            body: awaitBody
        )
        let secondAwaitResponse = await handler.handle(
            method: .POST,
            path: "/v2/pairing/await-outcome",
            body: awaitBody
        )

        #expect(introduceResponse.status != 429)
        #expect(awaitResponse.status != 429)
        #expect(secondAwaitResponse.status == 429)
    }

    @Test("host WebRTC busy returns a structured 503 error")
    func hostBusyReturnsStructured503() async throws {
        let fixture = try Self.makeSignalingFixture()
        let handler = makeHandler(handleSignalingOffer: { _ in
            .hostBusy("host is already handling an offer")
        })
        let body = try JSONEncoder.iso8601().encode(fixture.offer)

        let response = await handler.handle(method: .POST, path: "/v2/rtc/offer", body: body)

        #expect(response.status == 503)
        let error = try JSONDecoder.iso8601().decode(PairingErrorResponse.self, from: response.body)
        #expect(error.code == .hostBusy)
    }

    private static func makeChallengeRequest() throws -> SignalingChallengeRequest {
        try SignalingChallengeRequest(
            clientDeviceID: RemoteDeviceID(value: "client-v2"),
            clientNonce: Data(repeating: 0x11, count: 32),
            signingKey: Curve25519.Signing.PrivateKey()
        )
}

    private static func makeSignalingFixture() throws -> SignalingFixture {
        let hostKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let challenge = try SignalingChallengeResponse(
            hostDeviceID: RemoteDeviceID(value: "host-v2"),
            clientDeviceID: RemoteDeviceID(value: "client-v2"),
            clientNonce: Data(repeating: 0x11, count: 32),
            hostNonce: Data(repeating: 0x22, count: 32),
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            routes: [],
            signingKey: hostKey
        )
        let offer = try AuthenticatedSignalingOffer(
            challenge: challenge,
            sdp: "v=0\noffer\n",
            signingKey: clientKey
        )
        return SignalingFixture(
            offer: offer,
            answer: try AuthenticatedSignalingAnswer(
                offer: offer,
                sdp: "v=0\nanswer\n",
                routes: [],
                signingKey: hostKey
            )
        )
    }
}
