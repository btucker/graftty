import CryptoKit
import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

@Suite("PairingBeginCoordinator")
struct PairingBeginCoordinatorTests {

    private struct Fixture {
        let dir: URL
        let server: HostPairingServer
        let coordinator: PairingBeginCoordinator

        func cleanup() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeFixture(now: @escaping () -> Date = { Date() }) throws -> Fixture {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let identityStore = HostIdentityStore(directory: dir)
        _ = try identityStore.generateAndPersist()
        let peerStore = TrustedPeerStore(directory: dir)
        let session = HostPairingSession(
            identityStore: identityStore,
            peerStore: peerStore,
            now: now,
            hostDeviceID: .generate(),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            pairingURLProvider: { URL(string: "https://tailnet.example.com/v1/pairing")! }
        )
        let server = HostPairingServer(session: session)
        return Fixture(
            dir: dir,
            server: server,
            coordinator: PairingBeginCoordinator(server: server)
        )
    }

    @Test("begin starts host pairing session and returns payload")
    func beginReturnsPayload() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let lanBaseURL = URL(string: "http://host.local:9999/v1/pairing")!
        let result = await fx.coordinator.startIfIdle(validFor: 300, lanBaseURL: lanBaseURL)

        switch result {
        case .success(let payload):
            #expect(payload.version == 1)
            #expect(payload.nonce.bytes.isEmpty == false)
            #expect(payload.pairingURL == lanBaseURL)
            if case .awaitingClient(let statePayload, _) = await fx.server.currentState() {
                #expect(statePayload.nonce == payload.nonce)
            } else {
                Issue.record("Expected server to be awaiting a client")
            }
        case .failure(let error):
            Issue.record("Expected payload, got \(String(describing: error.code)): \(error.error)")
        }
    }

    @Test("begin rejects while a pairing session is active")
    func beginRejectsActiveSession() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let lanBaseURL = URL(string: "http://host.local:9999/v1/pairing")!
        guard case .success = await fx.coordinator.startIfIdle(validFor: 300, lanBaseURL: lanBaseURL) else {
            Issue.record("Expected first begin to succeed")
            return
        }

        let result = await fx.coordinator.startIfIdle(validFor: 300, lanBaseURL: lanBaseURL)
        guard case .failure(let error) = result else {
            Issue.record("Expected second begin to fail while active")
            return
        }
        #expect(error.code == .pairingBusy)
    }

    @Test("concurrent begin requests cannot both start sessions")
    func concurrentBeginIsAtomic() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let lanBaseURL = URL(string: "http://host.local:9999/v1/pairing")!
        let results = await withTaskGroup(of: Result<PairingPayload, PairingErrorResponse>.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    await fx.coordinator.startIfIdle(validFor: 300, lanBaseURL: lanBaseURL)
                }
            }

            var collected: [Result<PairingPayload, PairingErrorResponse>] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        let successes = results.compactMap { result -> PairingPayload? in
            guard case .success(let payload) = result else { return nil }
            return payload
        }
        let failures = results.compactMap { result -> PairingErrorResponse? in
            guard case .failure(let error) = result else { return nil }
            return error
        }

        #expect(successes.count == 1)
        #expect(failures.count == 1)
        #expect(failures.first?.code == .pairingBusy)
        #expect(successes.first?.pairingURL == lanBaseURL)
    }

    @Test("begin can replace an expired pairing session")
    func beginCanReplaceExpiredSession() async throws {
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let fx = try makeFixture(now: { clock })
        defer { fx.cleanup() }

        let lanBaseURL = URL(string: "http://host.local:9999/v1/pairing")!
        guard case .success(let firstPayload) = await fx.coordinator.startIfIdle(
            validFor: 1,
            lanBaseURL: lanBaseURL
        ) else {
            Issue.record("Expected first begin to succeed")
            return
        }

        clock = firstPayload.expiry.addingTimeInterval(1)
        let result = await fx.coordinator.startIfIdle(validFor: 300, lanBaseURL: lanBaseURL)

        guard case .success(let secondPayload) = result else {
            Issue.record("Expected expired session to be replaced")
            return
        }
        #expect(secondPayload.nonce != firstPayload.nonce)
    }
}
