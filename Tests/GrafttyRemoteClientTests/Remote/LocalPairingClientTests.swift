import CryptoKit
import Foundation
import GrafttyProtocol
import Testing

@testable import GrafttyRemoteClient

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
        let hostPublicKey: RemoteIdentityPublicKey
        let clientPublicKey: RemoteIdentityPublicKey
    }

    private func makeFixtures(dir: URL) throws -> Fixtures {
        let identityStore = ClientIdentityStore(directory: dir)
        let pinnedStore = PinnedHostStore(directory: dir)

        let clientPriv = try identityStore.generateAndPersist()
        let clientPub = try RemoteIdentityPublicKey(rawRepresentation: clientPriv.publicKey.rawRepresentation)

        let hostPub = try RemoteIdentityPublicKey(
            rawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        )

        let payload = PairingPayload(
            hostDeviceID: RemoteDeviceID(value: "host-1"),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            hostPublicKeyFingerprint: RemoteIdentityFingerprint(of: hostPub),
            nonce: RemotePairingNonce.generate(),
            expiry: Date().addingTimeInterval(300),
            pairingURL: URL(string: "https://host.local:8800/v2/pairing")!
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
            return { [self] request in
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
        try JSONEncoder.iso8601().encode(value)
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

    @Test("split pairing begins, introduces, shows verification, then pins only after confirm")
    func splitPairingFlowRequiresClientConfirmBeforeAwaitingOutcome() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = try makeFixtures(dir: dir)

        let stub = StubTransport()
        await stub.setResponse(for: "begin", body: try jsonData(fx.payload))
        try await stubHappyPath(
            on: stub,
            hostPublicKey: fx.hostPublicKey,
            expiry: fx.payload.expiry,
            outcome: .confirmed
        )

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: await stub.makeTransport()
        )

        let payload = try await client.beginPairing(baseURL: URL(string: "https://host.local:8800")!)
        let code = try await client.introduce(payload: payload)

        let recordedBeforeConfirm = await stub.recordedRequests
        #expect(recordedBeforeConfirm.map { $0.url?.path } == [
                "/v2/pairing/begin",
                "/v2/pairing/introduce",
        ])
        #expect(
            recordedBeforeConfirm[0].timeoutInterval
                == PairingProtocolDefaults.bootstrapRequestTimeout
        )
        #expect(code == RemotePairingTranscript(
            hostPublicKey: fx.hostPublicKey,
            clientPublicKey: fx.clientPublicKey,
            payload: fx.payload
        ).verificationCode())
        #expect(try fx.pinnedStore.list().isEmpty)

        let pinned = try await client.awaitOutcomeAndConfirm()

        #expect(pinned.id == fx.payload.hostDeviceID)
        let recordedAfterConfirm = await stub.recordedRequests
        #expect(recordedAfterConfirm.map { $0.url?.path } == [
                "/v2/pairing/begin",
                "/v2/pairing/introduce",
                "/v2/pairing/await-outcome",
        ])
        #expect(try fx.pinnedStore.list().contains(where: { $0.id == fx.payload.hostDeviceID }))
    }

    @Test("split pairing cancel before confirm stores no pinned host")
    func splitPairingCancelBeforeConfirmStoresNothing() async throws {
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

        _ = try await client.introduce(payload: fx.payload)
        fx.session.cancel()

        #expect(try fx.pinnedStore.list().isEmpty)
        await #expect(throws: ClientPairingSession.Error.wrongState(current: .cancelled)) {
            _ = try await client.awaitOutcomeAndConfirm()
        }
    }

    @Test("beginPairing accepts either remote root or pairing route base")
    func beginPairingAcceptsRootOrPairingRouteBase() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = try makeFixtures(dir: dir)

        let stub = StubTransport()
        await stub.setResponse(for: "begin", body: try jsonData(fx.payload))
        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: await stub.makeTransport()
        )

        _ = try await client.beginPairing(baseURL: URL(string: "https://host.local:8800/v2/pairing")!)

        let recorded = await stub.recordedRequests
        #expect(recorded.map { $0.url?.path } == ["/v2/pairing/begin"])
    }

    // MARK: - Fingerprint mismatch (REMOTE-1.2 client side enforcement at the wire)

    @Test("runPairing throws fingerprintMismatch if host returns a key whose fingerprint differs from QR payload — and does not pin the host")
    func fingerprintMismatchRejection() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = try makeFixtures(dir: dir)

        let imposterPub = try RemoteIdentityPublicKey(
            rawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        )

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
            // Expected before the confirmation long-poll begins.
        }

        let recorded = await stub.recordedRequests
        #expect(recorded.map { $0.url?.path } == ["/v2/pairing/introduce"])
        let pinnedList = try fx.pinnedStore.list()
        #expect(pinnedList.isEmpty)
    }

    // MARK: - Terminal-outcome trio (denied / expired / cancelled)

    /// Pairs each `PairingOutcome` the host can return with the
    /// `LocalPairingClient.Error` the test must observe.
    static let terminalOutcomeArguments: [(PairingOutcome, LocalPairingClient.Error)] = [
        (.denied, .denied),
        (.expired, .expired),
        (.cancelled, .cancelled),
    ]

    @Test(
        "runPairing throws the matching client error when host returns a terminal outcome",
        arguments: terminalOutcomeArguments
    )
    func terminalOutcomeMapping(outcome: PairingOutcome, expectedError: LocalPairingClient.Error) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = try makeFixtures(dir: dir)

        let stub = StubTransport()
        try await stubHappyPath(on: stub, hostPublicKey: fx.hostPublicKey, expiry: fx.payload.expiry, outcome: outcome)

        let client = LocalPairingClient(
            session: fx.session,
            identityStore: fx.identityStore,
            transport: await stub.makeTransport()
        )

        do {
            _ = try await client.runPairing(payload: fx.payload)
            Issue.record("Expected \(expectedError)")
        } catch let error as LocalPairingClient.Error {
            #expect(error == expectedError)
        }
    }

    // MARK: - Denied propagates to session state

    @Test("Denied outcome additionally transitions the session state to .denied")
    func deniedOutcomeUpdatesSessionState() async throws {
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

        _ = try? await client.runPairing(payload: fx.payload)

        if case .denied = fx.session.state {
            // expected
        } else {
            Issue.record("Expected denied session state, got \(fx.session.state)")
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

    @Test("introduce request body carries nonce, client identity, and protocol version")
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
        let decoded = try JSONDecoder.iso8601().decode(PairingIntroduceRequest.self, from: body)
        #expect(decoded.version == RemoteAccessProtocol.version)
        #expect(decoded.nonce == fx.payload.nonce)
        #expect(decoded.clientPublicKey == fx.clientPublicKey)
        #expect(decoded.clientDeviceID == fx.session.clientDeviceID)
        #expect(decoded.clientKind == fx.session.clientKind)
        #expect(decoded.clientDisplayName == fx.session.clientDisplayName)
    }
}
