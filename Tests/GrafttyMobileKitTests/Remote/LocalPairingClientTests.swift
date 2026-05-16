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

        // Pre-seed a client private key so we can compute the public key.
        let clientPriv = try identityStore.generateAndPersist()
        let clientPub = try RemoteIdentityPublicKey(rawRepresentation: clientPriv.publicKey.rawRepresentation)

        // Generate a host keypair for the fixture payload.
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

    /// Build a stub transport that replays a sequence of canned responses
    /// keyed by URL path suffix.
    private final class StubTransport: @unchecked Sendable {
        var responses: [String: (Data, Int)] = [:]
        var recordedRequests: [URLRequest] = []
        var lock = NSLock()

        func makeTransport() -> LocalPairingClient.Transport {
            return { [self] request in
                lock.lock()
                recordedRequests.append(request)
                let path = request.url?.path ?? ""
                let last = path.split(separator: "/").last.map(String.init) ?? ""
                let entry = responses[last]
                lock.unlock()

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
    }

    private func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    // MARK: - Happy path

    @Test("runPairing posts introduce, then await-outcome, and pins host on confirmed")
    func happyPath() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = try makeFixtures(dir: dir)

        let stub = StubTransport()
        stub.responses["introduce"] = (
            try jsonData(PairingIntroduceResponse(
                hostPublicKey: fx.hostPublicKey,
                expiry: fx.payload.expiry
            )),
            200
        )
        stub.responses["await-outcome"] = (
            try jsonData(PairingOutcomeResponse(outcome: .confirmed)),
            200
        )

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: stub.makeTransport()
        )

        let pinned = try await client.runPairing(payload: fx.payload)

        #expect(pinned.id == fx.payload.hostDeviceID)
        #expect(pinned.publicKey == fx.hostPublicKey)

        // Two requests, in order.
        #expect(stub.recordedRequests.count == 2)
        #expect(stub.recordedRequests[0].url?.absoluteString.hasSuffix("/introduce") == true)
        #expect(stub.recordedRequests[1].url?.absoluteString.hasSuffix("/await-outcome") == true)
        #expect(stub.recordedRequests.allSatisfy { $0.httpMethod == "POST" })

        // The pinned host should be persisted.
        let pinnedList = try fx.pinnedStore.list()
        #expect(pinnedList.contains(where: { $0.id == fx.payload.hostDeviceID }))
    }

    // MARK: - Fingerprint mismatch (REMOTE-1.2 client side enforcement at the wire)

    @Test("runPairing throws fingerprintMismatch if host returns a key whose fingerprint differs from QR payload")
    func fingerprintMismatchRejection() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = try makeFixtures(dir: dir)

        // Generate a *different* host key. The QR payload pinned the
        // first host's fingerprint, so this should mismatch.
        let imposterPriv = Curve25519.KeyAgreement.PrivateKey()
        let imposterPub = try RemoteIdentityPublicKey(rawRepresentation: imposterPriv.publicKey.rawRepresentation)

        let stub = StubTransport()
        stub.responses["introduce"] = (
            try jsonData(PairingIntroduceResponse(
                hostPublicKey: imposterPub,
                expiry: fx.payload.expiry
            )),
            200
        )
        // award-outcome shouldn't even be reached, but stub it just in case.
        stub.responses["await-outcome"] = (
            try jsonData(PairingOutcomeResponse(outcome: .confirmed)),
            200
        )

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: stub.makeTransport()
        )

        do {
            _ = try await client.runPairing(payload: fx.payload)
            Issue.record("Expected fingerprintMismatch")
        } catch ClientPairingSession.Error.fingerprintMismatch {
            // expected
        }

        // Should NOT have hit await-outcome.
        let paths = stub.recordedRequests.map { $0.url?.path ?? "" }
        #expect(!paths.contains(where: { $0.hasSuffix("await-outcome") }))

        // Host should NOT be pinned.
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
        stub.responses["introduce"] = (
            try jsonData(PairingIntroduceResponse(
                hostPublicKey: fx.hostPublicKey,
                expiry: fx.payload.expiry
            )),
            200
        )
        stub.responses["await-outcome"] = (
            try jsonData(PairingOutcomeResponse(outcome: .denied)),
            200
        )

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: stub.makeTransport()
        )

        do {
            _ = try await client.runPairing(payload: fx.payload)
            Issue.record("Expected denied")
        } catch LocalPairingClient.Error.denied {
            // expected
        }

        // Session state should reflect denial.
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
        stub.responses["introduce"] = (
            try jsonData(PairingIntroduceResponse(
                hostPublicKey: fx.hostPublicKey,
                expiry: fx.payload.expiry
            )),
            200
        )
        stub.responses["await-outcome"] = (
            try jsonData(PairingOutcomeResponse(outcome: .expired)),
            200
        )

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: stub.makeTransport()
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
        stub.responses["introduce"] = (
            try jsonData(PairingIntroduceResponse(
                hostPublicKey: fx.hostPublicKey,
                expiry: fx.payload.expiry
            )),
            200
        )
        stub.responses["await-outcome"] = (
            try jsonData(PairingOutcomeResponse(outcome: .cancelled)),
            200
        )

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: stub.makeTransport()
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
        stub.responses["introduce"] = (try jsonData(serverError), 410)

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: stub.makeTransport()
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
        stub.responses["introduce"] = (
            try jsonData(PairingIntroduceResponse(
                hostPublicKey: fx.hostPublicKey,
                expiry: fx.payload.expiry
            )),
            200
        )
        stub.responses["await-outcome"] = (try jsonData(serverError), 410)

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: stub.makeTransport()
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
        stub.responses["introduce"] = (Data("not json".utf8), 200)

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: stub.makeTransport()
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
        stub.responses["introduce"] = (
            try jsonData(PairingIntroduceResponse(
                hostPublicKey: fx.hostPublicKey,
                expiry: fx.payload.expiry
            )),
            200
        )
        stub.responses["await-outcome"] = (
            try jsonData(PairingOutcomeResponse(outcome: .confirmed)),
            200
        )

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: stub.makeTransport()
        )
        _ = try await client.runPairing(payload: fx.payload)

        let introduceReq = stub.recordedRequests.first { $0.url?.path.hasSuffix("/introduce") == true }
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
