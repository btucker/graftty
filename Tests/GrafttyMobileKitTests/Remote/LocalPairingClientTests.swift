#if canImport(UIKit)
import Testing
import Foundation
import CryptoKit
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite("LocalPairingClient Tests")
struct LocalPairingClientTests {

    // MARK: Helpers

    private func makeTempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Build a paired session + identityStore + a payload signed with a
    /// real host keypair. Returns everything the test needs to drive a
    /// successful pairing flow.
    private struct Fixtures {
        let session: ClientPairingSession
        let identityStore: ClientIdentityStore
        let pinnedStore: PinnedHostStore
        let payload: PairingPayload
        let hostPrivateKey: Curve25519.KeyAgreement.PrivateKey
        let hostPublicKey: RemoteIdentityPublicKey
        let clientPublicKey: RemoteIdentityPublicKey
    }

    private func makeFixtures(dir: URL) throws -> Fixtures {
        let identityStore = ClientIdentityStore(directory: dir)
        let pinnedStore = PinnedHostStore(directory: dir)

        let clientPriv = try identityStore.generateAndPersist()
        let clientPub = try RemoteIdentityPublicKey(rawRepresentation: clientPriv.publicKey.rawRepresentation)

        let hostPriv = Curve25519.KeyAgreement.PrivateKey()
        let hostPub = try RemoteIdentityPublicKey(rawRepresentation: hostPriv.publicKey.rawRepresentation)
        let hostFingerprint = RemoteIdentityFingerprint(of: hostPub)

        let payload = PairingPayload(
            hostDeviceID: RemoteDeviceID(value: "host-1"),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            hostPublicKeyFingerprint: hostFingerprint,
            nonce: RemotePairingNonce.generate(),
            expiry: Date().addingTimeInterval(300),
            pairingURL: URL(string: "https://host.local:8800/v1/pairing")!
        )

        let session = ClientPairingSession(
            identityStore: identityStore,
            pinnedHostStore: pinnedStore,
            clientDeviceID: RemoteDeviceID(value: "client-1"),
            clientKind: .iphone,
            clientDisplayName: "Client iPhone"
        )
        return Fixtures(
            session: session,
            identityStore: identityStore,
            pinnedStore: pinnedStore,
            payload: payload,
            hostPrivateKey: hostPriv,
            hostPublicKey: hostPub,
            clientPublicKey: clientPub
        )
    }

    /// Stub transport actor: replays canned responses keyed by URL path
    /// suffix and records every received request. Actor isolation
    /// removes the need for explicit locking.
    private actor StubTransport {
        private var responses: [String: (Data, Int)] = [:]
        private(set) var recordedRequests: [URLRequest] = []

        func setResponse(for pathSuffix: String, body: Data, status: Int = 200) {
            responses[pathSuffix] = (body, status)
        }

        func makeTransport() -> LocalPairingClient.Transport {
            return { [weak self] request in
                guard let self else { throw URLError(.cancelled) }
                let entry = await self.recordAndLookup(request)
                guard let (data, status) = entry else {
                    throw URLError(.unsupportedURL)
                }
                let http = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (data, http)
            }
        }

        private func recordAndLookup(_ request: URLRequest) -> (Data, Int)? {
            recordedRequests.append(request)
            let path = request.url?.path ?? ""
            let last = path.split(separator: "/").last.map(String.init) ?? ""
            return responses[last]
        }
    }

    private func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    /// Stub the standard happy-path responses (200 introduce, 200 await
    /// with the given outcome).
    private func stubHappyPath(
        on stub: StubTransport,
        hostPublicKey: RemoteIdentityPublicKey,
        expiry: Date,
        outcome: PairingOutcome
    ) async throws {
        await stub.setResponse(
            for: "introduce",
            body: try jsonData(PairingIntroduceResponse(hostPublicKey: hostPublicKey, expiry: expiry))
        )
        await stub.setResponse(
            for: "await-outcome",
            body: try jsonData(PairingOutcomeResponse(outcome: outcome))
        )
    }

    // MARK: - Happy path

    @Test("runPairing posts introduce, then await-outcome, and pins host on confirmed")
    func happyPath() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = try makeFixtures(dir: dir)

        let stub = StubTransport()
        try await stubHappyPath(on: stub, hostPublicKey: fx.hostPublicKey, expiry: fx.payload.expiry, outcome: .confirmed)

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: await stub.makeTransport()
        )

        let pinned = try await client.runPairing(payload: fx.payload)

        #expect(pinned.id == fx.payload.hostDeviceID)
        #expect(pinned.publicKey == fx.hostPublicKey)

        let recorded = await stub.recordedRequests
        #expect(recorded.count == 2)
        #expect(recorded[0].url?.absoluteString.hasSuffix("/introduce") == true)
        #expect(recorded[1].url?.absoluteString.hasSuffix("/await-outcome") == true)
        #expect(recorded.allSatisfy { $0.httpMethod == "POST" })

        let pinnedList = try fx.pinnedStore.list()
        #expect(pinnedList.contains(where: { $0.id == fx.payload.hostDeviceID }))
    }

    // MARK: - Fingerprint mismatch (REMOTE-1.2 client side enforcement at the wire)

    @Test("runPairing throws fingerprintMismatch if host returns a key whose fingerprint differs from QR payload — and does not pin the host")
    func fingerprintMismatchRejection() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = try makeFixtures(dir: dir)

        // Generate a *different* host key. The QR payload pinned the
        // first host's fingerprint, so the imposter response will
        // mismatch when ClientPairingSession.confirm runs.
        let imposterPriv = Curve25519.KeyAgreement.PrivateKey()
        let imposterPub = try RemoteIdentityPublicKey(rawRepresentation: imposterPriv.publicKey.rawRepresentation)

        let stub = StubTransport()
        try await stubHappyPath(on: stub, hostPublicKey: imposterPub, expiry: fx.payload.expiry, outcome: .confirmed)

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: await stub.makeTransport()
        )

        do {
            _ = try await client.runPairing(payload: fx.payload)
            Issue.record("Expected fingerprintMismatch")
        } catch ClientPairingSession.Error.fingerprintMismatch {
            // expected — REMOTE-1.2 protection fired inside session.confirm
        }

        // The protection that matters: no host was persisted, even
        // though await-outcome returned `.confirmed`. The fingerprint
        // check is the gating step inside ClientPairingSession.confirm.
        let pinnedList = try fx.pinnedStore.list()
        #expect(pinnedList.isEmpty)
    }

    // MARK: - Denied outcome

    @Test("runPairing throws .denied when host returns outcome=denied")
    func deniedOutcome() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = try makeFixtures(dir: dir)

        let stub = StubTransport()
        try await stubHappyPath(on: stub, hostPublicKey: fx.hostPublicKey, expiry: fx.payload.expiry, outcome: .denied)

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: await stub.makeTransport()
        )

        do {
            _ = try await client.runPairing(payload: fx.payload)
            Issue.record("Expected denied")
        } catch LocalPairingClient.Error.denied {
            // expected
        }

        if case .denied = fx.session.state {
            // expected
        } else {
            Issue.record("Expected denied session state, got \(fx.session.state)")
        }
    }

    // MARK: - Expired outcome

    @Test("runPairing throws .expired when host returns outcome=expired")
    func expiredOutcome() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = try makeFixtures(dir: dir)

        let stub = StubTransport()
        try await stubHappyPath(on: stub, hostPublicKey: fx.hostPublicKey, expiry: fx.payload.expiry, outcome: .expired)

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: await stub.makeTransport()
        )

        do {
            _ = try await client.runPairing(payload: fx.payload)
            Issue.record("Expected expired")
        } catch LocalPairingClient.Error.expired {
            // expected
        }
    }

    // MARK: - Cancelled outcome

    @Test("runPairing throws .cancelled when host returns outcome=cancelled")
    func cancelledOutcome() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = try makeFixtures(dir: dir)

        let stub = StubTransport()
        try await stubHappyPath(on: stub, hostPublicKey: fx.hostPublicKey, expiry: fx.payload.expiry, outcome: .cancelled)

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: await stub.makeTransport()
        )

        do {
            _ = try await client.runPairing(payload: fx.payload)
            Issue.record("Expected cancelled")
        } catch LocalPairingClient.Error.cancelled {
            // expected
        }
    }

    // MARK: - HTTP error on introduce

    @Test("runPairing surfaces server PairingErrorResponse from introduce as .serverError")
    func introduceHTTPErrorSurfacesAsServerError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = try makeFixtures(dir: dir)

        let serverError = PairingErrorResponse(code: .sessionExpired, error: "session expired")
        let stub = StubTransport()
        await stub.setResponse(for: "introduce", body: try jsonData(serverError), status: 410)

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: await stub.makeTransport()
        )

        do {
            _ = try await client.runPairing(payload: fx.payload)
            Issue.record("Expected serverError")
        } catch let LocalPairingClient.Error.serverError(decoded) {
            #expect(decoded.code == .sessionExpired)
        }
    }

    // MARK: - HTTP error on await-outcome

    @Test("runPairing surfaces server PairingErrorResponse from await-outcome as .serverError")
    func awaitOutcomeHTTPErrorSurfacesAsServerError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = try makeFixtures(dir: dir)

        let serverError = PairingErrorResponse(code: .unknownNonce, error: "stale nonce")
        let stub = StubTransport()
        await stub.setResponse(
            for: "introduce",
            body: try jsonData(PairingIntroduceResponse(
                hostPublicKey: fx.hostPublicKey,
                expiry: fx.payload.expiry
            ))
        )
        await stub.setResponse(for: "await-outcome", body: try jsonData(serverError), status: 410)

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: await stub.makeTransport()
        )

        do {
            _ = try await client.runPairing(payload: fx.payload)
            Issue.record("Expected serverError")
        } catch let LocalPairingClient.Error.serverError(decoded) {
            #expect(decoded.code == .unknownNonce)
        }
    }

    // MARK: - Malformed introduce JSON

    @Test("runPairing throws .decode if introduce returns 2xx with unparseable body")
    func malformedIntroduceBody() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = try makeFixtures(dir: dir)

        let stub = StubTransport()
        await stub.setResponse(for: "introduce", body: Data("not json".utf8))

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: await stub.makeTransport()
        )

        do {
            _ = try await client.runPairing(payload: fx.payload)
            Issue.record("Expected decode error")
        } catch LocalPairingClient.Error.decode {
            // expected
        }
    }

    // MARK: - Request shape

    @Test("introduce request body carries nonce + client identity + version 1")
    func introduceRequestBody() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = try makeFixtures(dir: dir)

        let stub = StubTransport()
        try await stubHappyPath(on: stub, hostPublicKey: fx.hostPublicKey, expiry: fx.payload.expiry, outcome: .confirmed)

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: await stub.makeTransport()
        )
        _ = try await client.runPairing(payload: fx.payload)

        let recorded = await stub.recordedRequests
        let introduceReq = recorded.first { $0.url?.path.hasSuffix("/introduce") == true }
        let body = try #require(introduceReq?.httpBody)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PairingIntroduceRequest.self, from: body)
        #expect(decoded.version == 1)
        #expect(decoded.nonce == fx.payload.nonce)
        #expect(decoded.clientPublicKey == fx.clientPublicKey)
        #expect(decoded.clientDeviceID == fx.session.clientDeviceID)
        #expect(decoded.clientKind == fx.session.clientKind)
        #expect(decoded.clientDisplayName == fx.session.clientDisplayName)
    }
}
#endif
