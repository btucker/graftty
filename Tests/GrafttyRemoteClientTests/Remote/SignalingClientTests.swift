import CryptoKit
import Foundation
import GrafttyProtocol
import Testing

@testable import GrafttyRemoteClient

@Suite("SignalingClient v2 authenticated route selection")
struct SignalingClientTests {

    @Test("""
    @spec REMOTE-2.3: The client shall verify the challenge and signaling answer \
    with the full host public key pinned during pairing; a missing, expired, \
    mismatched, or invalid signature shall fail closed without trying an \
    unauthenticated signaling endpoint.
    """)
    func authenticatedExchangeRejectsChallengeOrAnswerFromUnpinnedKey() async throws {
        let pinnedHostKey = Curve25519.Signing.PrivateKey()
        let attackerKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let hostDeviceID = RemoteDeviceID(value: "host-v2")
        let clientDeviceID = RemoteDeviceID(value: "client-v2")
        let route = RemoteConnectionRoute(
            kind: .lan,
            baseURL: URL(string: "http://studio.local:8800")!
        )
        let paths = CapturedPaths()
        let transport: SignalingClient.Transport = { request, body in
            paths.append(request.url?.path ?? "")
            let probe = try JSONDecoder.iso8601().decode(
                SignalingChallengeRequest.self,
                from: body
            )
            let forged = try SignalingChallengeResponse(
                hostDeviceID: hostDeviceID,
                clientDeviceID: clientDeviceID,
                clientNonce: probe.clientNonce,
                hostNonce: Data(repeating: 0x61, count: 32),
                expiresAt: Date(timeIntervalSince1970: 1_800_000_030),
                routes: [route],
                signingKey: attackerKey
            )
            return try Self.jsonResponse(request: request, value: forged)
        }
        let pinnedPublicKey = try RemoteIdentityPublicKey(
            rawRepresentation: pinnedHostKey.publicKey.rawRepresentation
        )

        await #expect(
            throws: SignalingClient.Error.authentication(
                "no route returned a valid host challenge"
            )
        ) {
            _ = try await SignalingClient(transport: transport)
                .authenticatedExchange(
                    routes: [route],
                    hostDeviceID: hostDeviceID,
                    hostPublicKey: pinnedPublicKey,
                    clientDeviceID: clientDeviceID,
                    clientKey: clientKey,
                    sdp: "v=0\noffer\n",
                    now: { Date(timeIntervalSince1970: 1_800_000_000) }
                )
        }
        #expect(paths.values == ["/v2/rtc/challenge"])

        let answerPaths = CapturedPaths()
        let forgedAnswerTransport: SignalingClient.Transport = {
            request,
            body in
            answerPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/\(RemoteAccessProtocol.challengePath)":
                let probe = try JSONDecoder.iso8601().decode(
                    SignalingChallengeRequest.self,
                    from: body
                )
                let challenge = try SignalingChallengeResponse(
                    hostDeviceID: hostDeviceID,
                    clientDeviceID: clientDeviceID,
                    clientNonce: probe.clientNonce,
                    hostNonce: Data(repeating: 0x62, count: 32),
                    expiresAt: Date(timeIntervalSince1970: 1_800_000_030),
                    routes: [route],
                    signingKey: pinnedHostKey
                )
                return try Self.jsonResponse(
                    request: request,
                    value: challenge
                )
            case "/\(RemoteAccessProtocol.offerPath)":
                let offer = try JSONDecoder.iso8601().decode(
                    AuthenticatedSignalingOffer.self,
                    from: body
                )
                let forgedAnswer = try AuthenticatedSignalingAnswer(
                    offer: offer,
                    sdp: "v=0\nforged-answer\n",
                    routes: [route],
                    signingKey: attackerKey
                )
                return try Self.jsonResponse(
                    request: request,
                    value: forgedAnswer
                )
            default:
                return Self.response(
                    request: request,
                    status: 404,
                    body: Data()
                )
            }
        }

        await #expect(
            throws: SignalingClient.Error.authentication(
                "host answer signature is invalid"
            )
        ) {
            _ = try await SignalingClient(
                transport: forgedAnswerTransport
            ).authenticatedExchange(
                routes: [route],
                hostDeviceID: hostDeviceID,
                hostPublicKey: pinnedPublicKey,
                clientDeviceID: clientDeviceID,
                clientKey: clientKey,
                sdp: "v=0\noffer\n",
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            )
        }
        #expect(answerPaths.values == [
            "/v2/rtc/challenge",
            "/v2/rtc/offer",
        ])
    }

    @Test("""
    @spec REMOTE-2.5: When connecting to a paired host, the client shall race \
    authenticated challenge probes across trusted routes, construct exactly one \
    signed SDP offer, race that same offer across the routes so one blackhole \
    cannot exhaust the challenge, and persist the winning route plus routes refreshed in \
    the signed answer.
    """)
    func authenticatedExchangeUsesTailscaleFallback() async throws {
        let hostKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let hostPublicKey = try RemoteIdentityPublicKey(
            rawRepresentation: hostKey.publicKey.rawRepresentation
        )
        let clientPublicKey = try RemoteIdentityPublicKey(
            rawRepresentation: clientKey.publicKey.rawRepresentation
        )
        let hostDeviceID = RemoteDeviceID(value: "host-v2")
        let clientDeviceID = RemoteDeviceID(value: "client-v2")
        let lanRoute = RemoteConnectionRoute(
            kind: .lan,
            baseURL: URL(string: "http://lan.invalid:8800")!
        )
        let tailRoute = RemoteConnectionRoute(
            kind: .tailscaleDNS,
            baseURL: URL(string: "http://studio.tailnet.ts.net:8800")!
        )
        let paths = CapturedPaths()
        let fake: SignalingClient.Transport = { request, body in
            paths.append(request.url?.absoluteString ?? "")
            switch request.url?.path {
            case "/\(RemoteAccessProtocol.challengePath)":
                if request.url?.host == tailRoute.baseURL.host {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let probe = try JSONDecoder.iso8601().decode(
                    SignalingChallengeRequest.self,
                    from: body
                )
                #expect(probe.isValid(using: clientPublicKey))
                let challenge = try SignalingChallengeResponse(
                    hostDeviceID: hostDeviceID,
                    clientDeviceID: clientDeviceID,
                    clientNonce: probe.clientNonce,
                    hostNonce: Data(repeating: 0x77, count: 32),
                    expiresAt: Date(timeIntervalSince1970: 1_800_000_030),
                    routes: [lanRoute, tailRoute],
                    signingKey: hostKey
                )
                return try Self.jsonResponse(request: request, value: challenge)
            case "/\(RemoteAccessProtocol.offerPath)":
                if request.url?.host == lanRoute.baseURL.host {
                    // Long enough that a sequential implementation cannot
                    // satisfy the bound below, while cancellation from the
                    // winning Tailscale task still ends this immediately.
                    try await Task.sleep(for: .seconds(10))
                    throw URLError(.networkConnectionLost)
                }
                let offer = try JSONDecoder.iso8601().decode(
                    AuthenticatedSignalingOffer.self,
                    from: body
                )
                #expect(offer.isValid(using: clientPublicKey))
                let answer = try AuthenticatedSignalingAnswer(
                    offer: offer,
                    sdp: "v=0\nanswer\n",
                    routes: [lanRoute, tailRoute],
                    signingKey: hostKey
                )
                return try Self.jsonResponse(request: request, value: answer)
            default:
                return Self.response(request: request, status: 404, body: Data())
            }
        }

        let started = ContinuousClock.now
        let result = try await SignalingClient(transport: fake)
            .authenticatedExchange(
                routes: [lanRoute, tailRoute],
                hostDeviceID: hostDeviceID,
                hostPublicKey: hostPublicKey,
                clientDeviceID: clientDeviceID,
                clientKey: clientKey,
                sdp: "v=0\noffer\n",
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            )

        // Keep scheduler headroom for the full suite, which runs thousands
        // of tests concurrently. A sequential fallback would take 10s.
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(result.route == tailRoute)
        #expect(result.answer.sdp == "v=0\nanswer\n")
        #expect(
            paths.values.contains {
                $0.contains("lan.invalid:8800/v2/rtc/challenge")
            })
        #expect(
            paths.values.contains {
                $0.contains("lan.invalid:8800/v2/rtc/offer")
            })
        #expect(
            paths.values.contains {
                $0.contains("studio.tailnet.ts.net:8800/v2/rtc/offer")
            })
    }

    private static func jsonResponse<Value: Encodable>(
        request: URLRequest,
        value: Value
    ) throws -> (Data, HTTPURLResponse) {
        response(
            request: request,
            status: 200,
            body: try JSONEncoder.iso8601().encode(value)
        )
    }

    private static func response(
        request: URLRequest,
        status: Int,
        body: Data
    ) -> (Data, HTTPURLResponse) {
        (
            body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }
}

private final class CapturedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ value: String) {
        lock.withLock {
            storage.append(value)
        }
    }
}
