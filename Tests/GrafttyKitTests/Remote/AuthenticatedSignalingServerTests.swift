import CryptoKit
import Foundation
import GrafttyProtocol
import Testing

@testable import GrafttyKit

@Suite("Authenticated signaling server")
struct AuthenticatedSignalingServerTests {
    private struct Fixture {
        let directory: URL
        let server: AuthenticatedSignalingServer
        let hostDeviceID: RemoteDeviceID
        let clientDeviceID: RemoteDeviceID
        let hostKey: Curve25519.Signing.PrivateKey
        let clientKey: Curve25519.Signing.PrivateKey

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture(
        now: @escaping @Sendable () -> Date = {
            Date(timeIntervalSince1970: 1_800_000_000)
        }
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let clientKey = Curve25519.Signing.PrivateKey()
        let hostDeviceID = RemoteDeviceID(value: "host-v2")
        let clientDeviceID = RemoteDeviceID(value: "client-v2")
        let identityStore = HostIdentityStore(directory: directory)
        let hostKey = try identityStore.generateAndPersist()
        let peerStore = TrustedPeerStore(directory: directory)
        try peerStore.add(
            TrustedPeer(
                id: clientDeviceID,
                kind: .iphone,
                publicKey: try RemoteIdentityPublicKey(
                    rawRepresentation: clientKey.publicKey.rawRepresentation
                ),
                displayName: "Phone",
                capabilities: .defaultsAfterPairing,
                pairedAt: now(),
                lastSeenAt: nil
            ))
        let routes = [
            RemoteConnectionRoute(
                kind: .lan,
                baseURL: URL(string: "http://studio.local:8800")!
            ),
            RemoteConnectionRoute(
                kind: .tailscaleDNS,
                baseURL: URL(string: "http://studio.tailnet.ts.net:8800")!
            ),
        ]
        return Fixture(
            directory: directory,
            server: AuthenticatedSignalingServer(
                identityStore: identityStore,
                peerStore: peerStore,
                hostDeviceID: hostDeviceID,
                routesProvider: { routes },
                now: now
            ),
            hostDeviceID: hostDeviceID,
            clientDeviceID: clientDeviceID,
            hostKey: hostKey,
            clientKey: clientKey
        )
    }

    @Test("""
    @spec REMOTE-2.2: Before allocating WebRTC resources, the paired-access \
    listener shall verify a signed challenge request from a currently trusted \
    client, return a short-lived host-signed challenge, bind that challenge to \
    at most one unique signed SDP offer, and return a cached answer for exact \
    offer retries.
    """)
    func happyPath() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let clientNonce = Data(repeating: 0x11, count: 32)
        let request = try SignalingChallengeRequest(
            clientDeviceID: fixture.clientDeviceID,
            clientNonce: clientNonce,
            signingKey: fixture.clientKey
        )
        let challenge = try #require(
            await fixture.server.issueChallenge(request).success
        )
        let hostPublicKey = try RemoteIdentityPublicKey(
            rawRepresentation: fixture.hostKey.publicKey.rawRepresentation
        )
        #expect(
            challenge.isValid(
                expectedHostID: fixture.hostDeviceID,
                expectedClientID: fixture.clientDeviceID,
                expectedClientNonce: clientNonce,
                now: Date(timeIntervalSince1970: 1_800_000_001),
                using: hostPublicKey
            ))

        let offer = try AuthenticatedSignalingOffer(
            challenge: challenge,
            sdp: "v=0\noffer\n",
            signingKey: fixture.clientKey
        )
        let disposition = try #require(
            await fixture.server.authenticateOffer(offer).success
        )
        guard case .new(let verified) = disposition else {
            Issue.record("Expected a new authenticated offer")
            return
        }
        let answer = try #require(
            await fixture.server.makeAnswer(
                sdp: "v=0\nanswer\n",
                for: verified
            ).success
        )
        #expect(answer.routes.contains { $0.kind == .tailscaleDNS })
        #expect(answer.isValid(for: offer, using: hostPublicKey))
    }

    @Test("an exact offer replay is pending until its signed answer is cached")
    func exactReplayReturnsCachedAnswer() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let request = try SignalingChallengeRequest(
            clientDeviceID: fixture.clientDeviceID,
            clientNonce: Data(repeating: 0x22, count: 32),
            signingKey: fixture.clientKey
        )
        let challenge = try #require(
            await fixture.server.issueChallenge(request).success
        )
        let offer = try AuthenticatedSignalingOffer(
            challenge: challenge,
            sdp: "v=0\n",
            signingKey: fixture.clientKey
        )
        let first = try #require(await fixture.server.authenticateOffer(offer).success)
        guard case .new(let verified) = first else {
            Issue.record("Expected a new offer")
            return
        }
        let pending = try #require(await fixture.server.authenticateOffer(offer).success)
        guard case .pending = pending else {
            Issue.record("Expected exact replay to report pending")
            return
        }

        let pendingRetry = Task {
            await fixture.server.awaitAnswer(
                for: offer,
                timeout: .seconds(1)
            )
        }
        await Task.yield()
        let answer = try #require(
            await fixture.server.makeAnswer(sdp: "v=0\nanswer\n", for: verified).success
        )
        #expect(try #require(await pendingRetry.value.success) == answer)
        let replay = try #require(await fixture.server.authenticateOffer(offer).success)
        guard case .cached(let cached) = replay else {
            Issue.record("Expected exact replay to return cached answer")
            return
        }
        #expect(cached == answer)
    }

    @Test("a different valid offer cannot reuse a claimed challenge")
    func alteredReplayIsRejected() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let request = try SignalingChallengeRequest(
            clientDeviceID: fixture.clientDeviceID,
            clientNonce: Data(repeating: 0x23, count: 32),
            signingKey: fixture.clientKey
        )
        let challenge = try #require(
            await fixture.server.issueChallenge(request).success
        )
        let original = try AuthenticatedSignalingOffer(
            challenge: challenge,
            sdp: "v=0\noriginal\n",
            signingKey: fixture.clientKey
        )
        let altered = try AuthenticatedSignalingOffer(
            challenge: challenge,
            sdp: "v=0\naltered\n",
            signingKey: fixture.clientKey
        )

        let first = try #require(await fixture.server.authenticateOffer(original).success)
        guard case .new = first else {
            Issue.record("Expected original offer to claim the challenge")
            return
        }
        guard case .failure(let error) = await fixture.server.authenticateOffer(altered)
        else {
            Issue.record("Expected altered replay rejection")
            return
        }
        #expect(error.code == .replayDetected)
    }

    @Test("unpaired and tampered requests are rejected before WebRTC")
    func invalidSignaturesAreRejected() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let attackerKey = Curve25519.Signing.PrivateKey()
        let invalidProbe = try SignalingChallengeRequest(
            clientDeviceID: fixture.clientDeviceID,
            clientNonce: Data(repeating: 0x33, count: 32),
            signingKey: attackerKey
        )
        guard
            case .failure(let probeError) =
                await fixture.server.issueChallenge(invalidProbe)
        else {
            Issue.record("Expected invalid probe rejection")
            return
        }
        #expect(probeError.code == .authenticationFailed)

        let validProbe = try SignalingChallengeRequest(
            clientDeviceID: fixture.clientDeviceID,
            clientNonce: Data(repeating: 0x44, count: 32),
            signingKey: fixture.clientKey
        )
        let challenge = try #require(
            await fixture.server.issueChallenge(validProbe).success
        )
        let signedOffer = try AuthenticatedSignalingOffer(
            challenge: challenge,
            sdp: "v=0\noriginal\n",
            signingKey: fixture.clientKey
        )
        let tampered = try JSONDecoder.iso8601().decode(
            AuthenticatedSignalingOffer.self,
            from: JSONEncoder.iso8601().encode(
                TamperedOffer(
                    source: signedOffer,
                    sdp: "v=0\ntampered\n"
                ))
        )
        guard
            case .failure(let offerError) =
                await fixture.server.authenticateOffer(tampered)
        else {
            Issue.record("Expected tampered offer rejection")
            return
        }
        #expect(offerError.code == .authenticationFailed)
        let validDisposition = try #require(
            await fixture.server.authenticateOffer(signedOffer).success
        )
        guard case .new = validDisposition else {
            Issue.record("A forged offer must not consume the legitimate challenge")
            return
        }
    }

    private struct TamperedOffer: Codable {
        let version: Int
        let hostDeviceID: RemoteDeviceID
        let clientDeviceID: RemoteDeviceID
        let clientNonce: Data
        let hostNonce: Data
        let expiresAt: Date
        let sdp: String
        let signature: Data

        init(source: AuthenticatedSignalingOffer, sdp: String) {
            version = source.version
            hostDeviceID = source.hostDeviceID
            clientDeviceID = source.clientDeviceID
            clientNonce = source.clientNonce
            hostNonce = source.hostNonce
            expiresAt = source.expiresAt
            self.sdp = sdp
            signature = source.signature
        }
    }
}

extension Result {
    fileprivate var success: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }
}
