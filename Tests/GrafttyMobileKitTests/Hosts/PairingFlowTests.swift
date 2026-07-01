#if canImport(UIKit)
import Testing
import Foundation
import CryptoKit
@testable import GrafttyMobileKit
import GrafttyProtocol

// MARK: - QR routing discrimination

@Suite("AddHostView.route(for:) QR discrimination")
struct AddHostViewRoutingTests {

    private func makePayload() -> PairingPayload {
        PairingPayload(
            hostDeviceID: RemoteDeviceID(value: "host-1"),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            hostPublicKeyFingerprint: RemoteIdentityFingerprint(
                of: try! RemoteIdentityPublicKey(rawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
            ),
            nonce: RemotePairingNonce.generate(),
            // Whole-second precision: ISO8601 round-tripping through
            // qrEncoded()/decodeQR truncates fractional seconds, so a
            // sub-second `expiry` here would make the round-tripped
            // payload compare unequal to the original.
            expiry: Date(timeIntervalSince1970: Date().addingTimeInterval(300).timeIntervalSince1970.rounded(.down)),
            pairingURL: URL(string: "http://mac.local:8800/v1/pairing")!
        )
    }

    @Test("A qrEncoded() pairing payload string routes to .pairing")
    func pairingPayloadRoutesToPairing() throws {
        let payload = makePayload()
        let encoded = try payload.qrEncoded()

        guard case .pairing(let decoded) = AddHostView.route(for: encoded) else {
            Issue.record("Expected .pairing route")
            return
        }
        #expect(decoded == payload)
    }

    @Test("A plain https URL routes to .url, unchanged from the pre-pairing behavior")
    func plainURLRoutesToURL() {
        guard case .url(let url) = AddHostView.route(for: "https://mac.local:8080") else {
            Issue.record("Expected .url route")
            return
        }
        #expect(url.absoluteString == "https://mac.local:8080")
    }

    @Test("Garbage input routes to .invalid")
    func garbageRoutesToInvalid() {
        #expect(AddHostView.route(for: "not a url or pairing string") == .invalid)
    }
}

// MARK: - ClientDeviceIDStore persistence

@Suite("ClientDeviceIDStore")
struct ClientDeviceIDStoreTests {

    private func makeTempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("loadOrGenerateAndPersist round-trips the same ID across store instances")
    func roundTripsAcrossInstances() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try ClientDeviceIDStore(directory: dir).loadOrGenerateAndPersist()
        let second = try ClientDeviceIDStore(directory: dir).loadOrGenerateAndPersist()

        #expect(first == second)
        #expect(!first.value.isEmpty)
    }

    @Test("A corrupt file is backed up and a fresh ID is generated")
    func recoversFromCorruptFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("client-device-id.json")
        try Data("not json".utf8).write(to: fileURL)

        let id = try ClientDeviceIDStore(directory: dir).loadOrGenerateAndPersist()
        #expect(!id.value.isEmpty)

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains("corrupt") }
        #expect(!backups.isEmpty)
    }
}

// MARK: - PairDeviceFlowModel state machine

@MainActor
@Suite("PairDeviceFlowModel")
struct PairDeviceFlowModelTests {

    // MARK: Fixtures (mirrors LocalPairingClientTests' fixture shape)

    private func makeTempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct Fixtures {
        let model: PairDeviceFlowModel
        let pinnedStore: PinnedHostStore
        let payload: PairingPayload
        let hostPublicKey: RemoteIdentityPublicKey
    }

    private func makeFixtures(dir: URL, stub: StubTransport, webBaseURL: URL? = nil) async throws -> Fixtures {
        let identityStore = ClientIdentityStore(directory: dir)
        let pinnedStore = PinnedHostStore(directory: dir)

        _ = try identityStore.generateAndPersist()

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
            pairingURL: URL(string: "http://host.local:8800/v1/pairing")!,
            webBaseURL: webBaseURL
        )

        let session = ClientPairingSession(
            identityStore: identityStore,
            pinnedHostStore: pinnedStore,
            clientDeviceID: RemoteDeviceID(value: "client-1"),
            clientKind: .iphone,
            clientDisplayName: "Client iPhone"
        )
        let client = LocalPairingClient(
            session: session,
            identityStore: identityStore,
            transport: await stub.makeTransport()
        )
        let model = PairDeviceFlowModel(payload: payload, session: session, client: client)

        return Fixtures(model: model, pinnedStore: pinnedStore, payload: payload, hostPublicKey: hostPub)
    }

    /// Stub transport actor: replays canned responses keyed by URL path
    /// suffix. Mirrors `LocalPairingClientTests.StubTransport`.
    private actor StubTransport {
        private var responses: [String: (Data, Int)] = [:]

        func setResponse(for pathSuffix: String, body: Data, status: Int = 200) {
            responses[pathSuffix] = (body, status)
        }

        func makeTransport() -> LocalPairingClient.Transport {
            return { [self] request in
                let entry = await self.lookup(request)
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

        private func lookup(_ request: URLRequest) -> (Data, Int)? {
            let path = request.url?.path ?? ""
            let last = path.split(separator: "/").last.map(String.init) ?? ""
            return responses[last]
        }
    }

    private func jsonData<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder.iso8601().encode(value)
    }

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

    @Test("""
    @spec REMOTE-1.5: When a pairing completes with host confirmation, the client shall pin the host identity and record the host device identifier on the saved host entry.
    """)
    func happyPathPinsHostAndSetsRemoteDeviceID() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stub = StubTransport()
        let fx = try await makeFixtures(dir: dir, stub: stub)
        try await stubHappyPath(on: stub, hostPublicKey: fx.hostPublicKey, expiry: fx.payload.expiry, outcome: .confirmed)

        await fx.model.run()

        guard case .success(let host, let addressUnconfirmed) = fx.model.state else {
            Issue.record("Expected .success, got \(String(describing: fx.model.state))")
            return
        }
        #expect(host.remoteDeviceID == fx.payload.hostDeviceID)
        #expect(host.label == fx.payload.hostDisplayName)
        #expect(addressUnconfirmed == true) // no webBaseURL in this fixture
        // Fallback address: pairing URL's host + the WebAccessSettings default port.
        #expect(host.baseURL == URL(string: "https://host.local:8799"))

        let pinnedList = try fx.pinnedStore.list()
        #expect(pinnedList.contains(where: { $0.id == fx.payload.hostDeviceID }))
    }

    @Test("A payload carrying webBaseURL uses it verbatim for the saved Host and does not flag addressUnconfirmed")
    func usesWebBaseURLWhenPresent() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let webBaseURL = URL(string: "https://host.tailnet.ts.net/")!
        let stub = StubTransport()
        let fx = try await makeFixtures(dir: dir, stub: stub, webBaseURL: webBaseURL)
        try await stubHappyPath(on: stub, hostPublicKey: fx.hostPublicKey, expiry: fx.payload.expiry, outcome: .confirmed)

        await fx.model.run()

        guard case .success(let host, let addressUnconfirmed) = fx.model.state else {
            Issue.record("Expected .success, got \(String(describing: fx.model.state))")
            return
        }
        #expect(host.baseURL == webBaseURL)
        #expect(addressUnconfirmed == false)
    }

    // MARK: - Denied path

    @Test("Denied outcome transitions to .denied and pins nothing")
    func deniedPathPinsNothing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stub = StubTransport()
        let fx = try await makeFixtures(dir: dir, stub: stub)
        try await stubHappyPath(on: stub, hostPublicKey: fx.hostPublicKey, expiry: fx.payload.expiry, outcome: .denied)

        await fx.model.run()

        guard case .denied = fx.model.state else {
            Issue.record("Expected .denied, got \(String(describing: fx.model.state))")
            return
        }
        let pinnedList = try fx.pinnedStore.list()
        #expect(pinnedList.isEmpty)
    }
}
#endif
