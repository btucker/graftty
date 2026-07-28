import Testing
import Foundation
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@MainActor
@Suite("HostPairingCoordinator Tests")
struct HostPairingCoordinatorTests {

    // MARK: Helpers

    private nonisolated static let webBaseURL = URL(string: "wss://mac.tail1234.ts.net:8799")!
    private static let encoder = JSONEncoder.iso8601()

    private struct Fixture {
        let dir: URL
        let coordinator: HostPairingCoordinator
        let peerStore: TrustedPeerStore

        @MainActor
        func cleanup() async {
            await coordinator.endPairing()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeFixture(
        admission: HostPairingAdmission? = nil
    ) throws -> Fixture {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let peerStore = TrustedPeerStore(directory: dir)
        let resolvedAdmission = admission ?? HostPairingAdmission()
        let coordinator = HostPairingCoordinator(
            identityStore: HostIdentityStore(directory: dir),
            trustedPeerStore: peerStore,
            deviceIDStore: HostDeviceIDStore(directory: dir),
            hostDisplayName: "Test Mac",
            webBaseURLProvider: { Self.webBaseURL },
            admission: resolvedAdmission
        )
        return Fixture(dir: dir, coordinator: coordinator, peerStore: peerStore)
    }

    /// Runs `body` against a fresh fixture, guaranteeing `cleanup()`
    /// (which ends any pairing and stops the listener) runs even when
    /// `body` throws partway through.
    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fx = try makeFixture()
        do {
            try await body(fx)
        } catch {
            await fx.cleanup()
            throw error
        }
        await fx.cleanup()
    }

    private func makeIntroduceRequest(nonce: RemotePairingNonce) -> PairingIntroduceRequest {
        PairingIntroduceRequest(
            nonce: nonce,
            clientPublicKey: try! RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 0xCC, count: 32)),
            clientDeviceID: RemoteDeviceID(value: "client-123"),
            clientKind: .iphone,
            clientDisplayName: "Client iPhone"
        )
    }

    /// POSTs the introduce request to the coordinator's live listener on
    /// loopback (the listener binds 0.0.0.0, so the LAN-IP payload URL's
    /// port is reachable via 127.0.0.1).
    private func postIntroduce(nonce: RemotePairingNonce, port: Int) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/pairing/introduce")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(makeIntroduceRequest(nonce: nonce))
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Polls `condition` until true or the deadline passes. The
    /// coordinator's published state advances on its 1s tick, so tests
    /// wait for the tick rather than assuming immediacy.
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - beginPairing

    @Test("beginPairing publishes a payload whose pairingURL points at the bound listener's /v1/pairing route and whose webBaseURL comes from the provider")
    func beginPairingPublishesPayload() async throws {
        try await withFixture { fx in
            await fx.coordinator.beginPairing()

            #expect(fx.coordinator.lastError == nil)
            let payload = try #require(fx.coordinator.payload)
            #expect(payload.pairingURL.scheme == "http")
            #expect(payload.pairingURL.path == "/v1/pairing")
            #expect(payload.webBaseURL == Self.webBaseURL)
            guard case .awaitingClient = fx.coordinator.state else {
                Issue.record("Expected .awaitingClient after beginPairing, got \(fx.coordinator.state)")
                return
            }

            // The advertised port is the actually-bound listener: an
            // introduce POST against it succeeds.
            let port = try #require(payload.pairingURL.port)
            let status = try await self.postIntroduce(nonce: payload.nonce, port: port)
            #expect(status == 200)
        }
    }

    // MARK: - REMOTE-1.3

    @Test("@spec REMOTE-1.3: When the host user confirms an introduced pairing, the application shall persist the introduced peer in the trusted peer store.")
    func confirmPersistsIntroducedPeer() async throws {
        try await withFixture { fx in
            await fx.coordinator.beginPairing()
            let payload = try #require(fx.coordinator.payload)
            let port = try #require(payload.pairingURL.port)

            let status = try await self.postIntroduce(nonce: payload.nonce, port: port)
            #expect(status == 200)

            // The coordinator's tick task surfaces the introduce as
            // .pendingConfirmation on its next 1s tick.
            try await self.waitUntil {
                if case .pendingConfirmation = fx.coordinator.state { return true }
                return false
            }

            await fx.coordinator.confirm()

            guard case .confirmed(let trustedPeer) = fx.coordinator.state else {
                Issue.record("Expected .confirmed after confirm(), got \(fx.coordinator.state)")
                return
            }
            #expect(trustedPeer.id == RemoteDeviceID(value: "client-123"))

            let persisted = try fx.peerStore.get(id: RemoteDeviceID(value: "client-123"))
            #expect(persisted != nil)
            #expect(persisted?.displayName == "Client iPhone")
        }
    }

    // MARK: - error handling

    @Test("beginPairing clears any previous error by setting lastError to nil at the start of a new attempt")
    func beginPairingClearsLastError() async throws {
        try await withFixture { fx in
            // Start a pairing that succeeds, so lastError is nil
            await fx.coordinator.beginPairing()
            #expect(fx.coordinator.lastError == nil)
            await fx.coordinator.endPairing()

            // Call beginPairing again; lastError should remain nil
            // (verifying that line 99 clears it at the start)
            await fx.coordinator.beginPairing()
            #expect(fx.coordinator.lastError == nil, "lastError should be cleared on new beginPairing")
        }
    }

    @Test("""
    @spec REMOTE-12.2: While any host pairing ceremony is active, the \
    application shall reject attempts to start a second ceremony through \
    another host pairing entry point without replacing the active session.
    """)
    func settingsAndLANPairingShareOneAdmission() async throws {
        let admission = HostPairingAdmission()
        let fx = try makeFixture(admission: admission)
        let lanSession = HostPairingSession(
            identityStore: HostIdentityStore(directory: fx.dir),
            peerStore: fx.peerStore,
            hostDeviceID: RemoteDeviceID(value: "host-mac"),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            pairingURLProvider: { URL(string: "http://host.local/v1/pairing")! }
        )
        let lanServer = HostPairingServer(session: lanSession)
        let lanCoordinator = RemoteMacHostPairingCoordinator(
            server: lanServer,
            admission: admission
        )

        await fx.coordinator.beginPairing()
        #expect(fx.coordinator.payload != nil)

        let blocked = await lanCoordinator.beginPairing(
            validFor: 300,
            lanBaseURL: URL(string: "http://host.local/v1/pairing")!
        )
        guard case .failure(let error) = blocked else {
            Issue.record("Expected LAN pairing to be rejected while Settings pairing is active")
            await lanCoordinator.cancel()
            await fx.cleanup()
            return
        }
        #expect(error.code == .pairingBusy)
        #expect(fx.coordinator.payload != nil)

        await fx.coordinator.endPairing()
        let admitted = await lanCoordinator.beginPairing(
            validFor: 300,
            lanBaseURL: URL(string: "http://host.local/v1/pairing")!
        )
        guard case .success = admitted else {
            Issue.record("Expected LAN pairing after Settings released admission")
            await lanCoordinator.cancel()
            await fx.cleanup()
            return
        }

        await fx.coordinator.beginPairing()
        #expect(fx.coordinator.payload == nil)
        #expect(fx.coordinator.lastError == "Another pairing session is already active.")
        guard case .awaitingClient = await lanServer.currentState() else {
            Issue.record("Settings pairing must not replace the active LAN ceremony")
            await lanCoordinator.cancel()
            await fx.cleanup()
            return
        }
        await lanCoordinator.cancel()
        await fx.cleanup()
    }

    // MARK: - endPairing

    @Test("endPairing stops the listener (connection refused) and returns the coordinator to a terminal state with no payload")
    func endPairingStopsListener() async throws {
        try await withFixture { fx in
            await fx.coordinator.beginPairing()
            let payload = try #require(fx.coordinator.payload)
            let port = try #require(payload.pairingURL.port)

            await fx.coordinator.endPairing()

            #expect(fx.coordinator.payload == nil)
            switch fx.coordinator.state {
            case .cancelled, .idle:
                break
            default:
                Issue.record("Expected a terminal/idle state after endPairing, got \(fx.coordinator.state)")
            }

            do {
                _ = try await self.postIntroduce(nonce: payload.nonce, port: port)
                Issue.record("Expected the connection to be refused after endPairing")
            } catch is URLError {
                // Expected: the pairing listener is gone (REMOTE-1.4).
            }
        }
    }

    /// A2: `beginPairing()` had no synchronous claim on `pairingServer`/
    /// `httpServer`, and `endPairing()` during the bind window saw nil
    /// fields and no-op'd — so a `beginPairing()` immediately followed by
    /// `endPairing()` (before the listener finishes binding) orphaned the
    /// listener for up to the session's ~300s validity: `endPairing()`
    /// returned having stopped nothing, and the in-flight `beginPairing()`
    /// resumed afterward and published a listener nobody would ever stop.
    ///
    /// `sessionGeneration` closes the race: `beginPairing()` checks it
    /// after every suspension point and tears down its own (by-then-
    /// stale) listener locally rather than publishing it. The
    /// interleaving is driven deterministically via the test-only
    /// begin-resume gate (mirrors `PairingHTTPServerTests`'
    /// `stopDuringStartLeavesNoLiveListener`, which widens the same
    /// category of bind-suspension window in `PairingHTTPServer`).
    @Test("beginPairing racing an immediate endPairing leaves no orphaned listener: endPairing tears down the in-flight listener and a later beginPairing has exactly one active listener")
    func beginPairingRacingImmediateEndPairingLeavesNoOrphan() async throws {
        try await withFixture { fx in
            var didPark = false
            let (releaseStream, releaseCont) = AsyncStream.makeStream(of: Void.self)
            fx.coordinator.beginPairingResumeGateForTesting = {
                didPark = true
                var iterator = releaseStream.makeAsyncIterator()
                _ = await iterator.next()
            }

            async let begin: Void = fx.coordinator.beginPairing()

            // Wait for beginPairing() to have bound its listener and
            // parked at the gate, still before publishing anything.
            while !didPark {
                await Task.yield()
            }
            #expect(fx.coordinator.payload == nil, "beginPairing must not have published yet")

            // endPairing() interleaves here: `pairingServer`/`httpServer`
            // are still nil (beginPairing hasn't assigned them), so
            // without the generation guard this would no-op and orphan
            // the listener beginPairing is about to resume into.
            await fx.coordinator.endPairing()

            // Release beginPairing(); it must recognize its generation is
            // stale and tear down its own already-bound listener rather
            // than publish it.
            releaseCont.yield(())
            await begin

            #expect(fx.coordinator.payload == nil, "beginPairing must not have published a stale listener")
            switch fx.coordinator.state {
            case .cancelled, .idle:
                break
            default:
                Issue.record("Expected endPairing to leave state idle/cancelled, got \(fx.coordinator.state)")
            }

            // A fresh beginPairing() (gate removed so it doesn't park)
            // has exactly one active listener — the introduce POST
            // against its payload's port succeeds.
            fx.coordinator.beginPairingResumeGateForTesting = nil
            await fx.coordinator.beginPairing()
            let payload = try #require(fx.coordinator.payload)
            let port = try #require(payload.pairingURL.port)
            let status = try await self.postIntroduce(nonce: payload.nonce, port: port)
            #expect(status == 200)

            await fx.coordinator.endPairing()
            #expect(fx.coordinator.payload == nil)
            switch fx.coordinator.state {
            case .cancelled, .idle:
                break
            default:
                Issue.record("Expected endPairing to clean state to idle/cancelled, got \(fx.coordinator.state)")
            }

            do {
                _ = try await self.postIntroduce(nonce: payload.nonce, port: port)
                Issue.record("Expected the connection to be refused after the final endPairing")
            } catch is URLError {
                // Expected: the pairing listener is gone (REMOTE-1.4).
            }
        }
    }
}
