import CryptoKit
import Foundation
import GrafttyProtocol
import Testing

@testable import Graftty
@testable import GrafttyKit

@Suite("RemoteMacHostPairingCoordinator")
struct RemoteMacHostPairingCoordinatorTests {
    private struct Fixture {
        let dir: URL
        let peerStore: TrustedPeerStore
        let server: HostPairingServer
        let coordinator: RemoteMacHostPairingCoordinator

        func cleanup() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @MainActor
    private func makeFixture(
        now: @escaping () -> Date = { Date() },
        tickInterval: Duration = .seconds(1)
    ) throws -> Fixture {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let identityStore = HostIdentityStore(directory: dir)
        _ = try identityStore.generateAndPersist()
        let peerStore = TrustedPeerStore(directory: dir)
        let session = HostPairingSession(
            identityStore: identityStore,
            peerStore: peerStore,
            now: now,
            hostDeviceID: RemoteDeviceID(value: "host-mac"),
            hostKind: .mac,
            hostDisplayName: "Host Mac",
            pairingURLProvider: { URL(string: "https://tailnet.example.com/v2/pairing")! }
        )
        let server = HostPairingServer(session: session)
        let coordinator = RemoteMacHostPairingCoordinator(
            server: server,
            tickInterval: tickInterval
        )
        return Fixture(
            dir: dir,
            peerStore: peerStore,
            server: server,
            coordinator: coordinator
        )
    }

    private func makeIntroduceRequest(
        nonce: RemotePairingNonce,
        clientDeviceID: RemoteDeviceID = RemoteDeviceID(value: "client-mac"),
        clientDisplayName: String = "Studio MacBook"
    ) throws -> PairingIntroduceRequest {
        PairingIntroduceRequest(
            nonce: nonce,
            clientPublicKey: try RemoteIdentityPublicKey(
                rawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
            ),
            clientDeviceID: clientDeviceID,
            clientKind: .mac,
            clientDisplayName: clientDisplayName
        )
    }

    private func waitForWaiters(on server: HostPairingServer, atLeast count: Int) async {
        while await server.pendingWaiterCount < count {
            await Task.yield()
        }
    }

    @Test("begin starts host pairing but exposes no prompt until client identity arrives")
    @MainActor
    func beginStartsWithoutPrompt() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        let result = await fx.coordinator.beginPairing(
            validFor: 300,
            lanBaseURL: URL(string: "http://host.local:9999/v2/pairing")!
        )

        guard case .success(let payload) = result else {
            Issue.record("Expected begin to return a pairing payload")
            return
        }
        #expect(payload.nonce.bytes.isEmpty == false)
        #expect(fx.coordinator.pendingRequest == nil)
    }

    @Test("introduce transitions to pending prompt with display name and verification code")
    @MainActor
    func introduceShowsPendingPrompt() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        guard case .success(let payload) = await fx.coordinator.beginPairing(
            validFor: 300,
            lanBaseURL: URL(string: "http://host.local:9999/v2/pairing")!
        ) else {
            Issue.record("Expected begin to succeed")
            return
        }

        let introduceResult = await fx.coordinator.handleIntroduce(
            try makeIntroduceRequest(nonce: payload.nonce)
        )

        guard case .success = introduceResult else {
            Issue.record("Expected introduce to succeed")
            return
        }
        let request = try #require(fx.coordinator.pendingRequest)
        #expect(request.id == payload.nonce)
        #expect(request.clientDisplayName == "Studio MacBook")

        let state = await fx.server.currentState()
        guard case .pendingConfirmation(_, _, _, _, _, let verificationCode, _) = state else {
            Issue.record("Expected host server to be pending confirmation")
            return
        }
        #expect(request.verificationCode == verificationCode)
    }

    @Test("confirm stores trusted peer and clears prompt")
    @MainActor
    func confirmStoresTrustedPeerAndClearsPrompt() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        let clientID = RemoteDeviceID(value: "trusted-client")

        guard case .success(let payload) = await fx.coordinator.beginPairing(
            validFor: 300,
            lanBaseURL: URL(string: "http://host.local:9999/v2/pairing")!
        ) else {
            Issue.record("Expected begin to succeed")
            return
        }
        _ = await fx.coordinator.handleIntroduce(
            try makeIntroduceRequest(
                nonce: payload.nonce,
                clientDeviceID: clientID,
                clientDisplayName: "Trusted Mac"
            )
        )
        #expect(fx.coordinator.pendingRequest != nil)

        let confirmResult = await fx.coordinator.confirm()

        guard case .success(let peer) = confirmResult else {
            Issue.record("Expected confirm to return trusted peer")
            return
        }
        #expect(peer.id == clientID)
        #expect(peer.displayName == "Trusted Mac")
        #expect(try fx.peerStore.get(id: clientID)?.id == clientID)
        #expect(fx.coordinator.pendingRequest == nil)
    }

    @Test("deny returns denied outcome and clears prompt")
    @MainActor
    func denyReturnsDeniedOutcomeAndClearsPrompt() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        guard case .success(let payload) = await fx.coordinator.beginPairing(
            validFor: 300,
            lanBaseURL: URL(string: "http://host.local:9999/v2/pairing")!
        ) else {
            Issue.record("Expected begin to succeed")
            return
        }
        _ = await fx.coordinator.handleIntroduce(
            try makeIntroduceRequest(nonce: payload.nonce)
        )

        let outcomeTask = Task {
            await fx.coordinator.handleAwaitOutcome(
                PairingAwaitOutcomeRequest(nonce: payload.nonce)
            )
        }
        await waitForWaiters(on: fx.server, atLeast: 1)

        await fx.coordinator.deny()
        let outcome = await outcomeTask.value

        guard case .success(let response) = outcome else {
            Issue.record("Expected await outcome to resolve after deny")
            return
        }
        #expect(response.outcome == .denied)
        #expect(fx.coordinator.pendingRequest == nil)
    }

    @Test("failed confirm after expiry wakes await outcome and clears prompt")
    @MainActor
    func failedConfirmAfterExpiryWakesAwaitOutcome() async throws {
        var clock = Date(timeIntervalSince1970: 1_710_000_000)
        let fx = try makeFixture(now: { clock })
        defer { fx.cleanup() }

        guard case .success(let payload) = await fx.coordinator.beginPairing(
            validFor: 300,
            lanBaseURL: URL(string: "http://host.local:9999/v2/pairing")!
        ) else {
            Issue.record("Expected begin to succeed")
            return
        }
        _ = await fx.coordinator.handleIntroduce(
            try makeIntroduceRequest(nonce: payload.nonce)
        )

        let outcomeTask = Task {
            await fx.coordinator.handleAwaitOutcome(
                PairingAwaitOutcomeRequest(nonce: payload.nonce)
            )
        }
        await waitForWaiters(on: fx.server, atLeast: 1)

        clock = clock.addingTimeInterval(301)
        let confirmResult = await fx.coordinator.confirm()
        guard case .failure = confirmResult else {
            Issue.record("Expected confirm to fail after expiry")
            return
        }

        let outcome = await outcomeTask.value
        guard case .success(let response) = outcome else {
            Issue.record("Expected await outcome to resolve after failed confirm")
            return
        }
        #expect(response.outcome == .expired)
        #expect(fx.coordinator.pendingRequest == nil)
    }

    @Test("expiry driver wakes await outcome without another request")
    @MainActor
    func expiryDriverWakesAwaitOutcome() async throws {
        var clock = Date(timeIntervalSince1970: 1_710_000_000)
        let fx = try makeFixture(
            now: { clock },
            tickInterval: .milliseconds(5)
        )
        defer { fx.cleanup() }

        guard case .success(let payload) = await fx.coordinator.beginPairing(
            validFor: 300,
            lanBaseURL: URL(string: "http://host.local:9999/v2/pairing")!
        ) else {
            Issue.record("Expected begin to succeed")
            return
        }
        _ = await fx.coordinator.handleIntroduce(
            try makeIntroduceRequest(nonce: payload.nonce)
        )
        let outcomeTask = Task {
            await fx.coordinator.handleAwaitOutcome(
                PairingAwaitOutcomeRequest(nonce: payload.nonce)
            )
        }
        await waitForWaiters(on: fx.server, atLeast: 1)

        clock = clock.addingTimeInterval(301)
        let outcome = await outcomeTask.value

        guard case .success(let response) = outcome else {
            Issue.record("Expected expiry tick to resolve await outcome")
            return
        }
        #expect(response.outcome == .expired)
        #expect(fx.coordinator.pendingRequest == nil)
    }

    @Test("second bootstrap replaces an unintroduced ceremony")
    @MainActor
    func secondBeginReplacesUnintroducedCeremony() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        let lanBaseURL = URL(string: "http://host.local:9999/v2/pairing")!

        guard case .success(let firstPayload) = await fx.coordinator.beginPairing(
            validFor: 300,
            lanBaseURL: lanBaseURL
        ) else {
            Issue.record("Expected first begin to succeed")
            return
        }

        guard case .success(let secondPayload) = await fx.coordinator.beginPairing(
            validFor: 300,
            lanBaseURL: lanBaseURL
        ) else {
            Issue.record("Expected a fresh bootstrap to replace the invisible lease")
            return
        }
        guard case .awaitingClient(let activePayload, _) = await fx.server.currentState() else {
            Issue.record("Expected replacement session to await a client")
            return
        }
        #expect(activePayload.nonce == secondPayload.nonce)
        #expect(activePayload.nonce != firstPayload.nonce)
        #expect(fx.coordinator.pendingRequest == nil)
    }

    @Test("remote cancel releases the active admission lease")
    @MainActor
    func remoteCancelReleasesAdmission() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        let lanBaseURL = URL(string: "http://host.local:9999/v2/pairing")!
        guard case .success(let payload) = await fx.coordinator.beginPairing(
            validFor: 300,
            lanBaseURL: lanBaseURL
        ) else {
            Issue.record("Expected begin to succeed")
            return
        }

        let cancelled = await fx.coordinator.handleCancel(
            PairingCancelRequest(nonce: payload.nonce)
        )
        #expect(cancelled == .success(PairingOutcomeResponse(outcome: .cancelled)))

        guard case .success = await fx.coordinator.beginPairing(
            validFor: 300,
            lanBaseURL: lanBaseURL
        ) else {
            Issue.record("Expected cancellation to release admission")
            return
        }
    }

    @Test("""
    @spec REMOTE-2.7: If the stable paired-access listener cannot bind, Settings shall show a clear error and shall not begin a pairing ceremony that advertises the unavailable listener.
    """)
    @MainActor
    func startupErrorIsPublished() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }

        fx.coordinator.setStartupError("Port unavailable")

        #expect(fx.coordinator.startupError == "Port unavailable")
        let result = await fx.coordinator.beginPairing(
            validFor: 300,
            lanBaseURL: URL(string: "http://host.local:9999/v2/pairing")!
        )
        guard case .failure(let error) = result else {
            Issue.record("Expected startup failure to prevent pairing")
            return
        }
        #expect(error.error == "Port unavailable")
    }

    @Test("""
    @spec REMOTE-12.2: Once a client identity has been introduced, the host shall reject a second pairing bootstrap without replacing the active verification ceremony; an unintroduced bootstrap may be safely replaced.
    """)
    @MainActor
    func introducedCeremonyRejectsSecondBootstrap() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        let lanBaseURL = URL(string: "http://host.local:9999/v2/pairing")!
        guard case .success(let payload) = await fx.coordinator.beginPairing(
            validFor: 300,
            lanBaseURL: lanBaseURL
        ) else {
            Issue.record("Expected begin to succeed")
            return
        }
        _ = await fx.coordinator.handleIntroduce(
            try makeIntroduceRequest(nonce: payload.nonce)
        )

        let second = await fx.coordinator.beginPairing(
            validFor: 300,
            lanBaseURL: lanBaseURL
        )

        guard case .failure(let error) = second else {
            Issue.record("Expected introduced ceremony to remain active")
            return
        }
        #expect(error.code == .pairingBusy)
        #expect(fx.coordinator.pendingRequest?.id == payload.nonce)
    }
}
