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
        let clientPublicKey: RemoteIdentityPublicKey
    }

    private func makeFixtures(dir: URL, stub: StubTransport, webBaseURL: URL? = nil) async throws -> Fixtures {
        let identityStore = ClientIdentityStore(directory: dir)
        let pinnedStore = PinnedHostStore(directory: dir)

        let clientPriv = try identityStore.generateAndPersist()
        let clientPub = try RemoteIdentityPublicKey(
            rawRepresentation: clientPriv.publicKey.rawRepresentation
        )

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

        return Fixtures(
            model: model,
            pinnedStore: pinnedStore,
            payload: payload,
            hostPublicKey: hostPub,
            clientPublicKey: clientPub
        )
    }

    /// Stub transport actor: replays canned responses keyed by URL path
    /// suffix. Mirrors `LocalPairingClientTests.StubTransport`, plus a
    /// per-path gate so a test can park a response mid-flight (e.g. hold
    /// `/await-outcome` open while the model sits in `.awaitingConfirmation`)
    /// and control exactly when — or whether — it resolves.
    private actor StubTransport {
        private var responses: [String: (Data, Int)] = [:]
        private var gatedPaths: Set<String> = []
        private var openGates: Set<String> = []
        private var cancelledGates: Set<String> = []
        private var waiters: [String: CheckedContinuation<Void, Swift.Error>] = [:]

        func setResponse(for pathSuffix: String, body: Data, status: Int = 200) {
            responses[pathSuffix] = (body, status)
        }

        /// Requests to `pathSuffix` block inside the transport closure until
        /// `release(_:)` is called (or the calling `Task` is cancelled,
        /// which throws `CancellationError` out of the transport — mirroring
        /// how `URLSession.data(for:)` throws `URLError(.cancelled)` when its
        /// enclosing task is cancelled).
        func gate(_ pathSuffix: String) {
            gatedPaths.insert(pathSuffix)
        }

        /// Lets any request to `pathSuffix` — already parked, or arriving
        /// later — proceed to look up its stubbed response.
        func release(_ pathSuffix: String) {
            openGates.insert(pathSuffix)
            if let waiter = waiters.removeValue(forKey: pathSuffix) {
                waiter.resume()
            }
        }

        func makeTransport() -> LocalPairingClient.Transport {
            return { [self] request in
                let path = Self.pathSuffix(of: request)
                try await self.waitForGate(path)
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

        private func waitForGate(_ pathSuffix: String) async throws {
            guard gatedPaths.contains(pathSuffix), !openGates.contains(pathSuffix) else { return }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
                    self.storeWaiter(continuation, for: pathSuffix)
                }
            } onCancel: {
                Task { await self.cancelWaiter(for: pathSuffix) }
            }
        }

        /// Runs synchronously inside `waitForGate`'s actor-isolated call
        /// frame — safe to touch actor state directly. Handles the race
        /// where `onCancel` already fired (marking the path cancelled)
        /// before this continuation was installed.
        private func storeWaiter(_ continuation: CheckedContinuation<Void, Swift.Error>, for pathSuffix: String) {
            if openGates.contains(pathSuffix) {
                continuation.resume()
            } else if cancelledGates.contains(pathSuffix) {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters[pathSuffix] = continuation
            }
        }

        private func cancelWaiter(for pathSuffix: String) {
            cancelledGates.insert(pathSuffix)
            if let waiter = waiters.removeValue(forKey: pathSuffix) {
                waiter.resume(throwing: CancellationError())
            }
        }

        private static func pathSuffix(of request: URLRequest) -> String {
            let path = request.url?.path ?? ""
            return path.split(separator: "/").last.map(String.init) ?? ""
        }

        private func lookup(_ request: URLRequest) -> (Data, Int)? {
            responses[Self.pathSuffix(of: request)]
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

    // MARK: - Awaiting-confirmation polling + cancellation

    /// Polls `model.state` (mirroring the model's own 100ms
    /// `reflectAwaitingConfirmation` cadence) until it reports
    /// `.awaitingConfirmation` or `timeout` elapses.
    private func waitUntilAwaitingConfirmation(
        _ model: PairDeviceFlowModel,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if case .awaitingConfirmation = model.state { return }
            if Date() > deadline {
                Issue.record("Timed out waiting for .awaitingConfirmation, got \(model.state)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("""
    While parked in .awaitingConfirmation, the model shall expose the verification code independently derivable from the introduce response's transcript, and the host's display name from the QR payload.
    """)
    func awaitingConfirmationExposesCodeAndHostName() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Whole-second precision: `RemotePairingTranscript.verificationCode()`
        // truncates `expiry` to whole seconds, and so does the iso8601 wire
        // round-trip below — using a sub-second `Date()` here could make the
        // independently-computed transcript disagree with the one built
        // from the (JSON round-tripped) introduce response by up to 1s.
        let introduceExpiry = Date(timeIntervalSince1970: Date().addingTimeInterval(300).timeIntervalSince1970.rounded(.down))

        let stub = StubTransport()
        let fx = try await makeFixtures(dir: dir, stub: stub)
        await stub.setResponse(
            for: "introduce",
            body: try jsonData(PairingIntroduceResponse(hostPublicKey: fx.hostPublicKey, expiry: introduceExpiry))
        )
        // Hold `/await-outcome` open so the model parks in
        // `.awaitingConfirmation` instead of racing straight to `.success` —
        // without this gate, the happy-path stub answers instantly and the
        // polling path + code extraction go unexercised.
        await stub.gate("await-outcome")

        let runTask = Task { await fx.model.run() }
        try await waitUntilAwaitingConfirmation(fx.model)

        guard case .awaitingConfirmation(let code, let hostDisplayName) = fx.model.state else {
            Issue.record("Expected .awaitingConfirmation, got \(fx.model.state)")
            runTask.cancel()
            return
        }

        let expectedTranscript = RemotePairingTranscript(
            hostPublicKey: fx.hostPublicKey,
            clientPublicKey: fx.clientPublicKey,
            nonce: fx.payload.nonce,
            expiry: introduceExpiry
        )
        #expect(code == expectedTranscript.verificationCode().display)
        #expect(hostDisplayName == fx.payload.hostDisplayName)

        await stub.setResponse(
            for: "await-outcome",
            body: try jsonData(PairingOutcomeResponse(outcome: .confirmed))
        )
        await stub.release("await-outcome")
        await runTask.value

        guard case .success(let host, _) = fx.model.state else {
            Issue.record("Expected .success after releasing the gate, got \(fx.model.state)")
            return
        }
        #expect(host.remoteDeviceID == fx.payload.hostDeviceID)
    }

    @Test("""
    @spec REMOTE-1.6: When the user cancels a pairing ceremony while it is parked in .awaitingConfirmation, the client shall tear down the in-flight await-outcome request and pin nothing, even if a host confirmation for that ceremony arrives afterward.
    """)
    func cancelWhileAwaitingConfirmationPreventsPinning() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let introduceExpiry = Date(timeIntervalSince1970: Date().addingTimeInterval(300).timeIntervalSince1970.rounded(.down))

        let stub = StubTransport()
        let fx = try await makeFixtures(dir: dir, stub: stub)
        await stub.setResponse(
            for: "introduce",
            body: try jsonData(PairingIntroduceResponse(hostPublicKey: fx.hostPublicKey, expiry: introduceExpiry))
        )
        await stub.gate("await-outcome")

        let runTask = Task { await fx.model.run() }
        try await waitUntilAwaitingConfirmation(fx.model)

        // User taps Cancel (or swipes the sheet away) while the host hasn't
        // responded yet.
        fx.model.cancel()

        // A confirmation for this ceremony arrives after the user already
        // cancelled (e.g. the Mac user was mid-tap when the client backed
        // out). It must not be able to pin a host.
        await stub.setResponse(
            for: "await-outcome",
            body: try jsonData(PairingOutcomeResponse(outcome: .confirmed))
        )
        await stub.release("await-outcome")

        await runTask.value

        if case .success = fx.model.state {
            Issue.record("cancel() must not let a pairing complete, got .success")
        }
        let pinnedList = try fx.pinnedStore.list()
        #expect(pinnedList.isEmpty)
    }
}
#endif
