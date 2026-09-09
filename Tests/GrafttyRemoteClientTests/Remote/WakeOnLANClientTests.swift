import CryptoKit
import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyRemoteClient

struct WakeOnLANClientTests {
    @Test("@spec REMOTE-2.11: When a Mac client sends a wake packet, the application shall broadcast only on active local IPv4 interfaces whose subnet contains the remembered host address.")
    func subnetSelection() {
        #expect(WakeOnLANClient.broadcastAddress(host: "192.168.1.10", local: "192.168.1.20", netmask: "255.255.255.0") == "192.168.1.255")
        #expect(WakeOnLANClient.broadcastAddress(host: "192.168.2.10", local: "192.168.1.20", netmask: "255.255.255.0") == nil)
        #expect(WakeOnLANClient.broadcastAddress(host: "studio.local", local: "192.168.1.20", netmask: "255.255.255.0") == nil)
        #expect(WakeOnLANClient.broadcastAddress(host: "192.168.1.255", local: "192.168.1.20", netmask: "255.255.255.0") == nil)
        #expect(WakeOnLANClient.broadcastAddress(host: "192.168.1.0", local: "192.168.1.20", netmask: "255.255.255.0") == nil)
        #expect(WakeOnLANClient.broadcastAddress(host: "192.168.1.10", local: "192.168.1.20", netmask: "0.0.0.0") == nil)
    }

    @Test("@spec REMOTE-2.12: When connecting to a paired host with verified wake addresses on a reachable local subnet, the Mac client shall attempt a wake and make at most three signaling attempts, while preserving authentication and cancellation.")
    func wakesThenRetriesUnavailableHost() async throws {
        let fixture = try Fixture()
        let events = Events()
        let client = SignalingClient(
            transport: { request, body in
                if request.url!.path.hasSuffix("challenge") {
                    let count = await events.challenge()
                    if count == 1 { throw URLError(.cannotConnectToHost) }
                }
                return try fixture.respond(request, body)
            },
            wake: { targets in
                #expect(targets == fixture.advertisement.targets)
                await events.record("wake")
                return true
            },
            wakeRetryDelay: { await events.record("delay") }
        )
        let result = try await fixture.exchange(client)
        #expect(result.answer.sdp == "answer")
        #expect(await events.values == ["wake", "challenge", "delay", "challenge"])
    }

    @Test
    func doesNotRetryWithoutSuccessfulWakeSend() async throws {
        let fixture = try Fixture()
        let events = Events()
        let client = SignalingClient(
            transport: { _, _ in
                _ = await events.challenge()
                throw URLError(.cannotConnectToHost)
            },
            wake: { _ in false },
            wakeRetryDelay: { await events.record("delay") }
        )
        await #expect(throws: SignalingClient.Error.self) { try await fixture.exchange(client) }
        #expect(await events.values == ["challenge"])
    }

    @Test
    func retriesAreBounded() async throws {
        let fixture = try Fixture()
        let events = Events()
        let client = SignalingClient(
            transport: { _, _ in
                _ = await events.challenge()
                throw URLError(.timedOut)
            },
            wake: { _ in true },
            wakeRetryDelay: { await events.record("delay") }
        )
        await #expect(throws: SignalingClient.Error.self) { try await fixture.exchange(client) }
        #expect(await events.values == ["challenge", "delay", "challenge", "delay", "challenge"])
    }

    @Test
    func doesNotRetryAuthenticationRejection() async throws {
        let fixture = try Fixture()
        let events = Events()
        let client = SignalingClient(
            transport: { request, _ in
                _ = await events.challenge()
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
            },
            wake: { _ in true },
            wakeRetryDelay: { await events.record("delay") }
        )
        await #expect(throws: SignalingClient.Error.self) { try await fixture.exchange(client) }
        #expect(await events.values == ["challenge"])
    }

    @Test
    func cancellationStopsWakeRetries() async throws {
        let fixture = try Fixture()
        let events = Events()
        let client = SignalingClient(
            transport: { _, _ in
                _ = await events.challenge()
                throw URLError(.cannotConnectToHost)
            },
            wake: { _ in true },
            wakeRetryDelay: { throw CancellationError() }
        )
        await #expect(throws: CancellationError.self) { try await fixture.exchange(client) }
        #expect(await events.values == ["challenge"])
    }

    @Test
    func untrustedWakeAdvertisementIsIgnored() async throws {
        let fixture = try Fixture()
        let other = try Fixture()
        let client = SignalingClient(
            transport: { try fixture.respond($0, $1) },
            wake: { _ in Issue.record("Used another host's wake addresses"); return true }
        )
        _ = try await fixture.exchange(client, advertisement: other.advertisement)
    }

    @Test
    func acceptsOnlyVerifiedWakeMetadataFromAnswer() async throws {
        let fixture = try Fixture()
        let other = try Fixture()
        for advertisement in [fixture.advertisement, other.advertisement] {
            let client = SignalingClient(
                transport: { try fixture.respond($0, $1, wakeOnLAN: advertisement) },
                wake: { _ in false }
            )
            let exchange = try await fixture.exchange(client)
            #expect(exchange.wakeOnLAN == (advertisement == fixture.advertisement ? advertisement : nil))
        }
    }
}

private actor Events {
    var values: [String] = []
    private var challenges = 0
    func record(_ value: String) { values.append(value) }
    func challenge() -> Int {
        values.append("challenge")
        challenges += 1
        return challenges
    }
}

private struct Fixture: Sendable {
    let key = Curve25519.Signing.PrivateKey()
    let clientKey = Curve25519.Signing.PrivateKey()
    let hostID = RemoteDeviceID(value: "host")
    let clientID = RemoteDeviceID(value: "client")
    let route = RemoteConnectionRoute(kind: .lan, baseURL: URL(string: "http://studio.local:8800")!)
    let advertisement: WakeOnLANAdvertisement

    init() throws {
        advertisement = try WakeOnLANAdvertisement(
            hostDeviceID: hostID,
            targets: [WakeOnLANTarget(macAddress: "02:11:22:33:44:55", ipv4Address: "192.168.1.10")],
            signingKey: key
        )
    }

    func exchange(_ client: SignalingClient, advertisement: WakeOnLANAdvertisement? = nil) async throws -> SignalingClient.AuthenticatedExchange {
        try await client.authenticatedExchange(
            routes: [route], hostDeviceID: hostID,
            hostPublicKey: RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation),
            clientDeviceID: clientID, clientKey: clientKey, sdp: "offer",
            wakeOnLAN: advertisement ?? self.advertisement
        )
    }

    func respond(_ request: URLRequest, _ body: Data, wakeOnLAN: WakeOnLANAdvertisement? = nil) throws -> (Data, HTTPURLResponse) {
        let data: Data
        if request.url!.path.hasSuffix("challenge") {
            let probe = try JSONDecoder.iso8601().decode(SignalingChallengeRequest.self, from: body)
            let challenge = try SignalingChallengeResponse(
                hostDeviceID: hostID, clientDeviceID: clientID, clientNonce: probe.clientNonce,
                hostNonce: Data(repeating: 1, count: 32), expiresAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 30),
                routes: [route], signingKey: key
            )
            data = try JSONEncoder.iso8601().encode(challenge)
        } else {
            let offer = try JSONDecoder.iso8601().decode(AuthenticatedSignalingOffer.self, from: body)
            data = try JSONEncoder.iso8601().encode(AuthenticatedSignalingAnswer(
                offer: offer, sdp: "answer", routes: [route], signingKey: key, wakeOnLAN: wakeOnLAN
            ))
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
