import CryptoKit
import Foundation
import GrafttyProtocol
import Testing

@testable import GrafttyKit

@Suite("HostPairingServer Tests")
struct HostPairingServerTests {

    // MARK: Helpers

    /// One-shot per-test fixture: a fresh temp dir, primed identity
    /// store, empty peer store, and a server wrapping all of it.
    private struct Fixture {
        let dir: URL
        let identityStore: HostIdentityStore
        let peerStore: TrustedPeerStore
        let privateKey: CryptoKit.Curve25519.Signing.PrivateKey
        let server: HostPairingServer

        func cleanup() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeFixture(now: @escaping () -> Date = { Date() }) throws -> Fixture {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let identityStore = HostIdentityStore(directory: dir)
        let privateKey = try identityStore.generateAndPersist()
        let peerStore = TrustedPeerStore(directory: dir)
        let session = HostPairingSession(
            identityStore: identityStore,
            peerStore: peerStore,
            now: now,
            hostDeviceID: .generate(),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            pairingURLProvider: { URL(string: "https://host.local:8800/v2/pairing")! }
        )
        return Fixture(
            dir: dir,
            identityStore: identityStore,
            peerStore: peerStore,
            privateKey: privateKey,
            server: HostPairingServer(session: session)
        )
    }

    private func makeClientPublicKey(byte: UInt8 = 0xCC) -> RemoteIdentityPublicKey {
        try! RemoteIdentityPublicKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    private func makeIntroduceRequest(
        nonce: RemotePairingNonce,
        clientKeyByte: UInt8 = 0xCC
    ) -> PairingIntroduceRequest {
        PairingIntroduceRequest(
            nonce: nonce,
            clientPublicKey: makeClientPublicKey(byte: clientKeyByte),
            clientDeviceID: RemoteDeviceID(value: "client-123"),
            clientKind: .iphone,
            clientDisplayName: "Client iPhone"
        )
    }

    /// Yield until at least `count` long-poll waiters are registered.
    /// Replaces a fixed `Task.sleep` so tests don't race the actor's
    /// scheduling under load.
    private func waitForWaiters(on server: HostPairingServer, atLeast count: Int) async {
        while await server.pendingWaiterCount < count {
            await Task.yield()
        }
    }

    private func waitUntil(
        timeout seconds: Double,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return await condition()
    }

    // MARK: - start

    @Test("start delegates to session and returns the payload")
    func startDelegatesToSession() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let payload = try await fx.server.start()
        #expect(payload.version == RemoteAccessProtocol.version)
    }

    // MARK: - handleIntroduce: happy path

    @Test("handleIntroduce on awaitingClient transitions to pendingConfirmation and returns host pubkey")
    func handleIntroduceHappyPath() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let payload = try await fx.server.start()
        let result = await fx.server.handleIntroduce(makeIntroduceRequest(nonce: payload.nonce))

        switch result {
        case .success(let response):
            let expected = try RemoteIdentityPublicKey(rawRepresentation: fx.privateKey.publicKey.rawRepresentation)
            #expect(response.hostPublicKey == expected)
            #expect(response.expiry == payload.expiry)
        case .failure(let err):
            Issue.record("Expected success, got failure: \(err.code) - \(err.error)")
        }

        let state = await fx.server.currentState()
        if case .pendingConfirmation = state {
            // expected
        } else {
            Issue.record("Expected pendingConfirmation state, got \(state)")
        }
    }

    // MARK: - handleIntroduce: unsupported version

    @Test("handleIntroduce rejects obsolete versions")
    func handleIntroduceRejectsUnsupportedVersion() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let payload = try await fx.server.start()
        let request = PairingIntroduceRequest(
            version: 1,
            nonce: payload.nonce,
            clientPublicKey: makeClientPublicKey(),
            clientDeviceID: RemoteDeviceID(value: "client-123"),
            clientKind: .iphone,
            clientDisplayName: "Client iPhone"
        )

        let result = await fx.server.handleIntroduce(request)
        guard case .failure(let err) = result else {
            Issue.record("Expected failure for unsupported version")
            return
        }
        #expect(err.code == .unsupportedVersion)
    }

    // MARK: - handleIntroduce: wrong nonce

    @Test("handleIntroduce rejects a request whose nonce does not match the active session")
    func handleIntroduceRejectsUnknownNonce() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        _ = try await fx.server.start()

        let request = makeIntroduceRequest(nonce: RemotePairingNonce.generate())
        let result = await fx.server.handleIntroduce(request)
        guard case .failure(let err) = result else {
            Issue.record("Expected failure for wrong nonce")
            return
        }
        #expect(err.code == .unknownNonce)
    }

    // MARK: - handleIntroduce: no active session

    @Test("handleIntroduce returns noActiveSession when start has not been called")
    func handleIntroduceWithoutStart() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let request = makeIntroduceRequest(nonce: RemotePairingNonce.generate())
        let result = await fx.server.handleIntroduce(request)
        guard case .failure(let err) = result else {
            Issue.record("Expected failure when no session active")
            return
        }
        #expect(err.code == .noActiveSession)
    }

    // MARK: - handleIntroduce: expired session

    @Test("handleIntroduce returns sessionExpired when expiry has passed before introduce")
    func handleIntroduceExpired() async throws {
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_750_000_000)
        let fx = try makeFixture(now: { clock })
        defer { fx.cleanup() }

        let payload = try await fx.server.start(validFor: 60)
        clock = payload.expiry.addingTimeInterval(1)

        let request = makeIntroduceRequest(nonce: payload.nonce)
        let result = await fx.server.handleIntroduce(request)
        guard case .failure(let err) = result else {
            Issue.record("Expected failure for expired session")
            return
        }
        #expect(err.code == .sessionExpired)
    }

    // MARK: - handleAwaitOutcome: confirmed

    @Test("handleAwaitOutcome returns confirmed once the host confirms")
    func handleAwaitOutcomeConfirmed() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let payload = try await fx.server.start()
        _ = await fx.server.handleIntroduce(makeIntroduceRequest(nonce: payload.nonce))

        async let outcomeResult = fx.server.handleAwaitOutcome(
            PairingAwaitOutcomeRequest(nonce: payload.nonce)
        )

        await waitForWaiters(on: fx.server, atLeast: 1)
        try await fx.server.confirm()

        let result = await outcomeResult
        guard case .success(let response) = result else {
            Issue.record("Expected confirmed outcome")
            return
        }
        #expect(response.outcome == .confirmed)
    }

    // MARK: - handleAwaitOutcome: denied

    @Test("handleAwaitOutcome returns denied once the host denies")
    func handleAwaitOutcomeDenied() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let payload = try await fx.server.start()
        _ = await fx.server.handleIntroduce(makeIntroduceRequest(nonce: payload.nonce))

        async let outcomeResult = fx.server.handleAwaitOutcome(
            PairingAwaitOutcomeRequest(nonce: payload.nonce)
        )

        await waitForWaiters(on: fx.server, atLeast: 1)
        await fx.server.deny()

        let result = await outcomeResult
        guard case .success(let response) = result else {
            Issue.record("Expected denied outcome")
            return
        }
        #expect(response.outcome == .denied)
    }

    // MARK: - handleAwaitOutcome: cancelled

    @Test("handleAwaitOutcome returns cancelled once the host cancels")
    func handleAwaitOutcomeCancelled() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let payload = try await fx.server.start()
        _ = await fx.server.handleIntroduce(makeIntroduceRequest(nonce: payload.nonce))

        async let outcomeResult = fx.server.handleAwaitOutcome(
            PairingAwaitOutcomeRequest(nonce: payload.nonce)
        )

        await waitForWaiters(on: fx.server, atLeast: 1)
        await fx.server.cancel()

        let result = await outcomeResult
        guard case .success(let response) = result else {
            Issue.record("Expected cancelled outcome")
            return
        }
        #expect(response.outcome == .cancelled)
    }

    // MARK: - handleAwaitOutcome: already terminal

    @Test("handleAwaitOutcome returns immediately if state is already terminal")
    func handleAwaitOutcomeImmediateWhenTerminal() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let payload = try await fx.server.start()
        _ = await fx.server.handleIntroduce(makeIntroduceRequest(nonce: payload.nonce))
        try await fx.server.confirm()

        let startedAt = Date()
        let result = await fx.server.handleAwaitOutcome(
            PairingAwaitOutcomeRequest(nonce: payload.nonce)
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        #expect(elapsed < 1.0, "Expected immediate return, took \(elapsed)s")

        guard case .success(let response) = result else {
            Issue.record("Expected confirmed outcome")
            return
        }
        #expect(response.outcome == .confirmed)
    }

    @Test("cancelling handleAwaitOutcome removes its pending waiter")
    func handleAwaitOutcomeCancellationRemovesWaiter() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let payload = try await fx.server.start()
        _ = await fx.server.handleIntroduce(makeIntroduceRequest(nonce: payload.nonce))

        let task = Task {
            await fx.server.handleAwaitOutcome(PairingAwaitOutcomeRequest(nonce: payload.nonce))
        }

        await waitForWaiters(on: fx.server, atLeast: 1)
        task.cancel()

        let waiterRemoved = await waitUntil(timeout: 1.0) {
            await fx.server.pendingWaiterCount == 0
        }
        #expect(waiterRemoved)

        if waiterRemoved {
            _ = await task.result
        } else {
            await fx.server.cancel()
            _ = await task.result
        }
    }

    // MARK: - handleAwaitOutcome: unknown nonce

    @Test("handleAwaitOutcome rejects await with a nonce that doesn't match active session")
    func handleAwaitOutcomeRejectsUnknownNonce() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let payload = try await fx.server.start()
        _ = await fx.server.handleIntroduce(makeIntroduceRequest(nonce: payload.nonce))

        let result = await fx.server.handleAwaitOutcome(
            PairingAwaitOutcomeRequest(nonce: RemotePairingNonce.generate())
        )
        guard case .failure(let err) = result else {
            Issue.record("Expected failure for unknown nonce")
            return
        }
        #expect(err.code == .unknownNonce)
    }

    // MARK: - handleAwaitOutcome: unsupported version

    @Test("handleAwaitOutcome rejects non-1 versions")
    func handleAwaitOutcomeRejectsUnsupportedVersion() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let payload = try await fx.server.start()
        let result = await fx.server.handleAwaitOutcome(
            PairingAwaitOutcomeRequest(version: 99, nonce: payload.nonce)
        )
        guard case .failure(let err) = result else {
            Issue.record("Expected failure for unsupported version")
            return
        }
        #expect(err.code == .unsupportedVersion)
    }

    // MARK: - Multiple concurrent waiters

    @Test("Multiple concurrent handleAwaitOutcome callers all receive the same outcome")
    func multipleConcurrentWaitersAllResume() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let payload = try await fx.server.start()
        _ = await fx.server.handleIntroduce(makeIntroduceRequest(nonce: payload.nonce))

        async let result1 = fx.server.handleAwaitOutcome(
            PairingAwaitOutcomeRequest(nonce: payload.nonce)
        )
        async let result2 = fx.server.handleAwaitOutcome(
            PairingAwaitOutcomeRequest(nonce: payload.nonce)
        )

        await waitForWaiters(on: fx.server, atLeast: 2)
        try await fx.server.confirm()

        let r1 = await result1
        let r2 = await result2

        if case .success(let response) = r1 { #expect(response.outcome == .confirmed) } else {
            Issue.record("waiter 1 did not get confirmed")
        }
        if case .success(let response) = r2 { #expect(response.outcome == .confirmed) } else {
            Issue.record("waiter 2 did not get confirmed")
        }
    }

    // MARK: - Restart abandons prior session

    @Test("Calling start again with an active session abandons the prior one — prior nonce becomes unknown")
    func restartAbandonsPriorSession() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let originalPayload = try await fx.server.start()
        let restartedPayload = try await fx.server.start()

        #expect(originalPayload.nonce != restartedPayload.nonce)

        let result = await fx.server.handleIntroduce(makeIntroduceRequest(nonce: originalPayload.nonce))
        guard case .failure(let err) = result else {
            Issue.record("Expected unknownNonce for stale nonce after restart")
            return
        }
        #expect(err.code == .unknownNonce)
    }

    // MARK: - Restart wakes prior waiters with .cancelled

    @Test("Calling start while a long-poll is in flight wakes the waiter with .cancelled")
    func restartWakesPriorWaitersWithCancelled() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let payload = try await fx.server.start()
        _ = await fx.server.handleIntroduce(makeIntroduceRequest(nonce: payload.nonce))

        async let outcomeResult = fx.server.handleAwaitOutcome(
            PairingAwaitOutcomeRequest(nonce: payload.nonce)
        )

        await waitForWaiters(on: fx.server, atLeast: 1)
        _ = try await fx.server.start()

        let result = await outcomeResult
        guard case .success(let response) = result else {
            Issue.record("Expected cancelled outcome from restart")
            return
        }
        #expect(response.outcome == .cancelled)
    }
}
