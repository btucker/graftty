#if canImport(UIKit)
import Testing
import Foundation
import CryptoKit
@testable import GrafttyMobileKit
import GrafttyProtocol

// MARK: - Nearby paired-device discovery

@Suite("NearbyMacBrowser candidate decoding")
struct NearbyMacBrowserCandidateTests {
    @Test("""
    @spec IOS-2.1: While adding a Mac, GrafttyMobile shall browse the shared \
    `_graftty._tcp` device-pairing service, accept only protocol-compatible \
    TXT records, and treat the resolved address as an untrusted routing hint \
    until the user confirms the pairing verification code.
    """)
    func compatibleAdvertisementBecomesCandidate() throws {
        let fingerprint = RemoteIdentityFingerprint(
            of: try RemoteIdentityPublicKey(
                rawRepresentation: Curve25519.Signing.PrivateKey()
                    .publicKey.rawRepresentation
            )
        )
        let txt = try GrafttyBonjourService.encodeTXT(.init(
            deviceID: RemoteDeviceID(value: "mac-1"),
            label: "Studio Mac",
            fingerprint: fingerprint,
            protocolVersion: GrafttyBonjourService.discoveryVersion,
            pairingStatus: .required
        ))

        let candidate = NearbyMacBrowser.candidate(
            name: "fallback-name",
            hostName: "studio.local.",
            port: 51_234,
            txtRecordData: txt
        )

        #expect(candidate?.deviceID == RemoteDeviceID(value: "mac-1"))
        #expect(candidate?.label == "Studio Mac")
        #expect(candidate?.fingerprint == fingerprint)
        #expect(candidate?.baseURL == URL(string: "http://studio.local:51234"))
    }

    @Test("Incompatible protocol advertisements are ignored")
    func incompatibleProtocolIsRejected() throws {
        let fingerprint = RemoteIdentityFingerprint(
            of: try RemoteIdentityPublicKey(
                rawRepresentation: Curve25519.Signing.PrivateKey()
                    .publicKey.rawRepresentation
            )
        )
        let txt = try GrafttyBonjourService.encodeTXT(.init(
            deviceID: RemoteDeviceID(value: "mac-1"),
            label: "Studio Mac",
            fingerprint: fingerprint,
            protocolVersion: "999",
            pairingStatus: .required
        ))

        #expect(NearbyMacBrowser.candidate(
            name: "Studio Mac",
            hostName: "studio.local.",
            port: 51_234,
            txtRecordData: txt
        ) == nil)
    }

    @Test("A compatible advertised protocol range is accepted")
    func compatibleProtocolRangeBecomesCandidate() throws {
        let fingerprint = RemoteIdentityFingerprint(
            of: try RemoteIdentityPublicKey(
                rawRepresentation: Curve25519.Signing.PrivateKey()
                    .publicKey.rawRepresentation
            )
        )
        let txt = try GrafttyBonjourService.encodeTXT(.init(
            deviceID: RemoteDeviceID(value: "mac-1"),
            label: "Studio Mac",
            fingerprint: fingerprint,
            protocolVersion: "1-2",
            pairingStatus: .required
        ))

        #expect(NearbyMacBrowser.candidate(
            name: "Studio Mac",
            hostName: "studio.local.",
            port: 51_234,
            txtRecordData: txt
        ) != nil)
    }

    @Test("A candidate remains until its final service disappears")
    func registryRetainsDuplicateIdentityAdvertisements() throws {
        let candidate = try makeCandidate(deviceID: "mac-1")
        let first = NearbyMacServiceKey(
            name: "first",
            type: "_graftty._tcp.",
            domain: "local."
        )
        let second = NearbyMacServiceKey(
            name: "second",
            type: "_graftty._tcp.",
            domain: "local."
        )
        var registry = NearbyMacCandidateRegistry()

        registry.publish(candidate, for: first)
        registry.publish(candidate, for: second)
        registry.remove(first)
        #expect(registry.candidates == [candidate])

        registry.remove(second)
        #expect(registry.candidates.isEmpty)
    }

    @Test("Re-resolving one service replaces its old identity")
    func registryRemovesGhostCandidateAfterIdentityChange() throws {
        let old = try makeCandidate(deviceID: "mac-1")
        let replacement = try makeCandidate(deviceID: "mac-2")
        let key = NearbyMacServiceKey(
            name: "studio",
            type: "_graftty._tcp.",
            domain: "local."
        )
        var registry = NearbyMacCandidateRegistry()

        registry.publish(old, for: key)
        registry.publish(replacement, for: key)

        #expect(registry.candidates == [replacement])
    }

    private func makeCandidate(deviceID: String) throws -> NearbyMac {
        let fingerprint = RemoteIdentityFingerprint(
            of: try RemoteIdentityPublicKey(
                rawRepresentation: Curve25519.Signing.PrivateKey()
                    .publicKey.rawRepresentation
            )
        )
        return NearbyMac(
            deviceID: RemoteDeviceID(value: deviceID),
            label: deviceID,
            fingerprint: fingerprint,
            baseURL: URL(string: "http://\(deviceID).local:51234")!,
            pairingStatus: .required
        )
    }
}

// MARK: - Pairing bootstrap address validation

@Suite("AddHostView pairing bootstrap")
struct AddHostViewRoutingTests {
    @Test("""
    @spec IOS-2.2: When Bonjour discovery is unavailable, GrafttyMobile shall \
    accept a manually entered HTTP(S) LAN address only as the bootstrap for \
    the same authenticated device-pairing ceremony; it shall never save the \
    address as an unpaired host.
    """)
    func manualHTTPAddressBecomesPairingBootstrap() {
        #expect(
            AddHostView.manualPairingBaseURL("http://mac.local:8080") ==
                URL(string: "http://mac.local:8080")
        )
        #expect(
            AddHostView.manualPairingBaseURL("https://mac.local:8080/") ==
                URL(string: "https://mac.local:8080/")
        )
    }

    @Test("Non-network and hostless values cannot bootstrap pairing")
    func invalidManualAddressesAreRejected() {
        #expect(AddHostView.manualPairingBaseURL("not a url") == nil)
        #expect(AddHostView.manualPairingBaseURL("file:///tmp/graftty") == nil)
        #expect(AddHostView.manualPairingBaseURL("http:///missing-host") == nil)
    }
}

// MARK: - PairDeviceFlowView.buildModel

@Suite("PairDeviceFlowView.buildModel")
struct PairDeviceFlowViewBuildModelTests {

    private func makePayload() -> PairingPayload {
        PairingPayload(
            hostDeviceID: RemoteDeviceID(value: "host-1"),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            hostPublicKeyFingerprint: RemoteIdentityFingerprint(
                of: try! RemoteIdentityPublicKey(rawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
            ),
            nonce: RemotePairingNonce.generate(),
            expiry: Date().addingTimeInterval(300),
            pairingURL: URL(string: "http://mac.local:8800/v1/pairing")!
        )
    }

    @Test("A usable directory builds a model")
    func succeedsWithUsableDirectory() throws {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = PairDeviceFlowView.buildModel(payload: makePayload(), directory: dir)
        #expect(model != nil)
    }

    /// A nil return here is what lets the view present a failed/retry
    /// state — previously the caller silently proceeded with no model,
    /// leaving the view stuck on `connectingView` forever with no way out.
    @Test("""
    @spec REMOTE-1.10: When `ClientDeviceIDStore` cannot read or persist a client device identity, `PairDeviceFlowView.buildModel` shall return nil so the view can present a failed state whose Retry re-attempts model construction, rather than an indefinite connecting spinner.
    """)
    func returnsNilWhenDeviceIDStoreDirectoryIsUnusable() throws {
        // A regular file where `ClientDeviceIDStore` needs a directory: its
        // `createDirectory(at:withIntermediateDirectories:)` call throws
        // because a non-directory item already occupies that path.
        let blockedPath = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("blocking file".utf8).write(to: blockedPath)
        defer { try? FileManager.default.removeItem(at: blockedPath) }

        let model = PairDeviceFlowView.buildModel(payload: makePayload(), directory: blockedPath)
        #expect(model == nil)
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
        #expect(addressUnconfirmed == false)
        // Device pairing uses the root of the authenticated LAN
        // pairing/signaling listener, not the legacy Web Access port.
        #expect(host.baseURL == URL(string: "http://host.local:8800"))

        let pinnedList = try fx.pinnedStore.list()
        #expect(pinnedList.contains(where: { $0.id == fx.payload.hostDeviceID }))
    }

    @Test("A legacy QR payload carrying webBaseURL remains compatible")
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
    While parked in .awaitingConfirmation, the model shall expose the verification code independently derivable from the introduce response's transcript, and the discovered host's display name from the pairing payload.
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

        // The confirmed outcome races `session.cancel()`: `runPairing`
        // still calls `session.confirm(...)` after the outcome resolves,
        // but the session is already `.cancelled`, so `confirm` throws
        // `ClientPairingSession.Error.wrongState(current: .cancelled)`.
        // Before the `wasCancelled` guard, that error fell through to the
        // generic `.failure` branch and flashed `.failed("wrongState(...)")`
        // even though the user had already cancelled — assert the exact
        // terminal state, not just "not success", so that regression stays
        // caught.
        guard case .cancelled = fx.model.state else {
            Issue.record("Expected .cancelled, got \(fx.model.state)")
            return
        }
        let pinnedList = try fx.pinnedStore.list()
        #expect(pinnedList.isEmpty)
    }

    /// Direct, deterministic coverage of the `wasCancelled`-checked-first
    /// guard: the `await-outcome` gate reproduction above only exercises
    /// the case where `pairingTask.cancel()` wins the race via the
    /// transport's own `CancellationError` path (already mapped correctly
    /// pre-fix). The actual regression — an arbitrary pairing failure
    /// (e.g. `ClientPairingSession.Error.wrongState` from `confirm()`
    /// losing a race with `session.cancel()`) surfacing as a spurious
    /// `.failed(...)` after the user already cancelled — has no I/O
    /// boundary to gate, so this drives it structurally: `cancel()` before
    /// `run()` ever starts a `pairingTask` (a no-op for the not-yet-created
    /// task and the still-`.idle` session, but it must still latch
    /// `wasCancelled`), then a malformed `introduce` response produces a
    /// `LocalPairingClient.Error.decode` — a failure `run()` doesn't map to
    /// `.denied`/`.expired`/`.cancelled` — which must still present as
    /// `.cancelled`, not the raw decode error.
    @Test("""
    @spec REMOTE-1.9: While a pairing ceremony has already been cancelled, the client shall present .cancelled for any subsequent pairing failure rather than the failure's raw error message.
    """)
    func cancelBeforeRunPresentsCancelledForAnyFailure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stub = StubTransport()
        let fx = try await makeFixtures(dir: dir, stub: stub)
        await stub.setResponse(for: "introduce", body: Data("not json".utf8))

        fx.model.cancel()
        await fx.model.run()

        guard case .cancelled = fx.model.state else {
            Issue.record("Expected .cancelled, got \(fx.model.state)")
            return
        }
    }
}
#endif
