import CryptoKit
import Foundation
import GrafttyProtocol
import Testing

@testable import GrafttyKit

/// Host-side integration coverage for the full device-pairing ceremony,
/// driven end-to-end over real loopback HTTP in a single process.
///
/// Unlike `PairingHTTPServerTests` (which exercises individual routes) and
/// `HostPairingCoordinatorTests` (which exercises the `Graftty`-target
/// coordinator against the in-process `HostPairingServer` actor directly),
/// this suite plays the *client* role purely through raw `URLSession` POSTs
/// of the `GrafttyProtocol` wire types — mirroring what a real mobile client
/// would send — while asserting on host-side state and storage after each
/// step. It intentionally introduces no new `@spec` ID: every property
/// exercised here (REMOTE-1.2's verification-code parity, REMOTE-1.3's
/// confirm-persists behavior) already has dedicated behavioral coverage
/// elsewhere; this suite is pure integration/plumbing verification that the
/// pieces work together over a real socket.
@Suite("Pairing end-to-end over loopback HTTP")
struct PairingEndToEndTests {

    private static let encoder = JSONEncoder.iso8601()
    private static let decoder = JSONDecoder.iso8601()

    @Test("Full ceremony over real loopback HTTP: introduce, matching verification code, confirm, and trusted-peer persistence")
    func fullCeremonyOverLoopbackHTTP() async throws {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            try await runCeremony(dir: dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        try? FileManager.default.removeItem(at: dir)
    }

    private func runCeremony(dir: URL) async throws {
        // ---- Host-side setup: real identity + peer stores, real bound port ----
        let identityStore = HostIdentityStore(directory: dir)
        let hostPrivateKey = try identityStore.generateAndPersist()
        let hostPublicKey = try RemoteIdentityPublicKey(
            rawRepresentation: hostPrivateKey.publicKey.rawRepresentation
        )

        let peerStore = TrustedPeerStore(directory: dir)
        let session = HostPairingSession(
            identityStore: identityStore,
            peerStore: peerStore,
            hostDeviceID: .generate(),
            hostKind: .mac,
            hostDisplayName: "E2E Test Mac",
            pairingURLProvider: { URL(string: "https://host.local:8800/v2/pairing")! }
        )
        let pairingServer = HostPairingServer(session: session)
        let httpServer = PairingHTTPServer(pairingServer: pairingServer)
        let port = try await httpServer.start(host: "127.0.0.1", port: 0)

        do {
            try await driveCeremony(
                hostPublicKey: hostPublicKey,
                session: session,
                pairingServer: pairingServer,
                peerStore: peerStore,
                port: port
            )
        } catch {
            await httpServer.stop()
            throw error
        }
        await httpServer.stop()
    }

    private func driveCeremony(
        hostPublicKey: RemoteIdentityPublicKey,
        session: HostPairingSession,
        pairingServer: HostPairingServer,
        peerStore: TrustedPeerStore,
        port: Int
    ) async throws {
        let payload = try await pairingServer.start(validFor: 300)

        // ---- Client side: raw HTTP POSTs of the wire types, no mobile module ----
        let clientDeviceID = RemoteDeviceID.generate()
        let clientPublicKey = try RemoteIdentityPublicKey(
            rawRepresentation: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        )

        let introduceRequest = PairingIntroduceRequest(
            nonce: payload.nonce,
            clientPublicKey: clientPublicKey,
            clientDeviceID: clientDeviceID,
            clientKind: .iphone,
            clientDisplayName: "E2E Test iPhone"
        )
        let (introduceStatus, introduceData) = try await Self.post(
            "/v2/pairing/introduce",
            port: port,
            body: introduceRequest
        )
        #expect(introduceStatus == 200)
        let introduceResponse = try Self.decoder.decode(PairingIntroduceResponse.self, from: introduceData)
        #expect(introduceResponse.hostPublicKey == hostPublicKey)

        // ---- Host-side state: pendingConfirmation with matching verification code ----
        guard case .pendingConfirmation(
            let statePublicKey,
            let stateDeviceID,
            let stateKind,
            let stateDisplayName,
            _,
            let stateVerificationCode,
            _
        ) = session.state else {
            Issue.record("Expected .pendingConfirmation after introduce, got \(session.state)")
            return
        }
        #expect(statePublicKey == clientPublicKey)
        #expect(stateDeviceID == clientDeviceID)
        #expect(stateKind == .iphone)
        #expect(stateDisplayName == "E2E Test iPhone")

        // Independently derive the transcript from wire traffic alone (as a
        // real client would) and confirm it lands on the same verification
        // code the host is displaying — both sides derive the same code.
        let independentTranscript = RemotePairingTranscript(
            hostPublicKey: introduceResponse.hostPublicKey,
            clientPublicKey: clientPublicKey,
            payload: payload
        )
        #expect(independentTranscript.verificationCode() == stateVerificationCode)

        // ---- await-outcome long-poll, synchronized via pendingWaiterCount ----
        async let outcomeCall = Self.post(
            "/v2/pairing/await-outcome",
            port: port,
            body: PairingAwaitOutcomeRequest(nonce: payload.nonce)
        )
        while await pairingServer.pendingWaiterCount < 1 {
            await Task.yield()
        }
        try await pairingServer.confirm()

        let (outcomeStatus, outcomeData) = try await outcomeCall
        #expect(outcomeStatus == 200)
        let outcomeResponse = try Self.decoder.decode(PairingOutcomeResponse.self, from: outcomeData)
        #expect(outcomeResponse.outcome == .confirmed)

        // ---- Trusted peer persisted with the client's ID + public key ----
        let storedPeer = try peerStore.get(id: clientDeviceID)
        #expect(storedPeer?.id == clientDeviceID)
        #expect(storedPeer?.publicKey == clientPublicKey)
    }

    /// Mirrors `PairingHTTPServerTests.post` — POSTs a JSON-encoded body to
    /// `path` on the loopback listener and returns the raw status + bytes.
    private static func post(
        _ path: String,
        port: Int,
        body: some Encodable
    ) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return (0, data)
        }
        return (http.statusCode, data)
    }
}
