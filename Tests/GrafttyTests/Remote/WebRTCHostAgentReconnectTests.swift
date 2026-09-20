import CryptoKit
import Foundation
import Testing
@testable import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import WebRTC

private actor ReconnectRegistrationGate {
    private var isOpen = false
    private var hasArrived = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasArrived = true
        let arrivals = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in arrivals {
            waiter.resume()
        }
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilArrived() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// W4 follow-up bug: `installSSHHandler`'s `sshInstallStarted` guard is a
/// per-connection one-shot latch — it must flip back to `false` when a
/// connection tears down, so a RECONNECT's fresh data channel can install
/// SSH again. `close()` reset `sshTransport` / `authenticatedRegistration`
/// / `peerConnection` / `dataChannel` / `state` but NOT `sshInstallStarted`,
/// so a reconnect (`acceptOffer` after `close()`, which admission explicitly
/// permits from `.closed`) opened a new data
/// channel whose `onOpen` called `installSSHHandler`, which saw the stale
/// `true` left over from the PRIOR connection and returned immediately —
/// SSH never re-installed, leaving the reconnected peer with a dead
/// channel. This makes W4's REMOTE-2.1/3.2 reconnect paths non-latent.
///
/// This suite can't drive `installSSHHandler` through a real data channel
/// without native libwebrtc (forbidden in this suite — see
/// `SignalingHandlerOutcomeTests` for the CI-hang history it was extracted
/// to avoid). Instead it calls `installSSHHandler()` directly with
/// `dataChannel` left at its default `nil`: the method still flips
/// `sshInstallStarted` to `true` before its `guard let dc = dataChannel`
/// early-return, so the latch behavior is exercised with zero native WebRTC
/// or NIOSSH work — see `installSSHHandler`'s doc comment.
@Suite("WebRTCHostAgent re-arms the sshInstallStarted latch on close (W4 follow-up)")
struct WebRTCHostAgentReconnectTests {

    @Test("""
    @spec REMOTE-11.10: When a signed signaling offer explicitly requests a \
    reconnect for the paired device that owns the current host connection \
    lifecycle, the application shall replace that negotiating or connected \
    lifecycle immediately; offers from another device and ordinary offers \
    shall remain busy without disturbing it.
    """)
    func explicitReconnectOnlyReplacesTheSameViewingMac() async throws {
        let agent = Self.makeHostAgent()
        let originalViewer = RemoteDeviceID(value: "original-viewer")
        let otherViewer = RemoteDeviceID(value: "other-viewer")

        await agent.beginConnectionLifecycle(clientDeviceID: originalViewer)
        await agent.setStateForTesting(.connected)

        await #expect(throws: WebRTCHostAgent.HostError.busy) {
            try await agent.prepareToAcceptOffer(
                clientDeviceID: originalViewer,
                replacingExistingConnection: false
            )
        }
        #expect(await agent.state == .connected)

        await #expect(throws: WebRTCHostAgent.HostError.busy) {
            try await agent.prepareToAcceptOffer(
                clientDeviceID: otherViewer,
                replacingExistingConnection: true
            )
        }
        #expect(await agent.state == .connected)

        try await agent.prepareToAcceptOffer(
            clientDeviceID: originalViewer,
            replacingExistingConnection: true
        )
        #expect(
            await agent.state == .answering,
            "the replacement must reserve the slot before teardown yields"
        )

        let supersededGeneration = await agent.connectionGenerationForTesting
        await agent.setStateForTesting(.answering)
        await #expect(throws: WebRTCHostAgent.HostError.busy) {
            try await agent.prepareToAcceptOffer(
                clientDeviceID: originalViewer,
                replacingExistingConnection: false
            )
        }
        await #expect(throws: WebRTCHostAgent.HostError.busy) {
            try await agent.prepareToAcceptOffer(
                clientDeviceID: otherViewer,
                replacingExistingConnection: true
            )
        }
        try await agent.prepareToAcceptOffer(
            clientDeviceID: originalViewer,
            replacingExistingConnection: true
        )
        await agent.close(ifGeneration: supersededGeneration)
        #expect(
            await agent.state == .answering,
            "the superseded negotiation must not close its replacement"
        )
    }

    @Test("""
    @spec REMOTE-11.13: If peer-connection allocation fails after an offer \
    reserves the host slot, then the application shall close that lifecycle \
    so a later authenticated offer can connect immediately.
    """)
    func allocationFailureDoesNotWedgeTheHostBusy() async throws {
        let agent = Self.makeHostAgent()
        await agent.failPeerConnectionAllocationForTesting()

        let offer = RTCSessionDescription(type: .offer, sdp: "")
        await #expect(throws: WebRTCHostAgent.HostError.peerConnectionInitFailed) {
            _ = try await agent.acceptOffer(
                offer,
                clientDeviceID: RemoteDeviceID(value: "viewer")
            )
        }
        #expect(await agent.state == .closed)

        try await agent.prepareToAcceptOffer(
            clientDeviceID: RemoteDeviceID(value: "viewer"),
            replacingExistingConnection: false
        )
        #expect(await agent.state == .answering)
    }

    @Test("SSH authentication must match the identity that claimed signaling")
    func sshIdentityMismatchClosesTheReplacementConnection() async throws {
        let registry = SSHConnectionRegistry()
        let store = TrustedPeerStore(directory: Self.tempDir())
        let signalingDevice = RemoteDeviceID(value: "signaling-device")
        let sshDevice = RemoteDeviceID(value: "ssh-device")
        try store.add(Self.makePeer(id: signalingDevice))
        try store.add(Self.makePeer(id: sshDevice))
        let agent = Self.makeHostAgent(
            trustedPeerStore: store,
            registry: registry
        )

        await agent.beginConnectionLifecycle(clientDeviceID: signalingDevice)
        await agent.setStateForTesting(.connected)
        await agent.registerAuthenticatedConnection(deviceID: sshDevice)

        #expect(await agent.state == .closed)
        #expect(await registry.count == 0)
    }

    @Test("""
    @spec REMOTE-11.11: When the current host ICE connection does not return \
    to a connected state within five seconds after disconnecting, the \
    application shall close it and release the single-client slot; if ICE \
    recovers first, the application shall keep the connection.
    """)
    func staleDisconnectedTransportReleasesTheHostSlotAfterGrace() async throws {
        let agent = Self.makeHostAgent()

        await agent.beginConnectionLifecycle()
        await agent.setStateForTesting(.connected)
        await agent.noteIceDisconnectedForTesting(timeout: .milliseconds(20))

        for _ in 0..<100 {
            if await agent.state == .closed { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(
            await agent.state == .closed,
            "a stale disconnected transport must stop returning hostBusy forever"
        )
    }

    @Test("ICE recovery cancels the stale-connection deadline")
    func recoveredDisconnectedTransportKeepsTheHostSlot() async throws {
        let agent = Self.makeHostAgent()

        await agent.beginConnectionLifecycle()
        await agent.setStateForTesting(.connected)
        await agent.noteIceDisconnectedForTesting(timeout: .milliseconds(20))
        await agent.noteIceRecoveredForTesting()
        try await Task.sleep(for: .milliseconds(40))

        #expect(await agent.state == .connected)
    }

    @Test("an older disconnected callback cannot override newer ICE recovery")
    func reorderedIceRecoveryDoesNotArmAStaleDeadline() async throws {
        let agent = Self.makeHostAgent()
        await agent.beginConnectionLifecycle()
        await agent.setStateForTesting(.connected)

        await agent.applyIceStateForTesting(
            .connected,
            sequence: 2,
            timeout: .milliseconds(10)
        )
        await agent.applyIceStateForTesting(
            .disconnected,
            sequence: 1,
            timeout: .milliseconds(10)
        )
        try await Task.sleep(for: .milliseconds(25))

        #expect(await agent.state == .connected)
    }

    @Test("an expired ICE deadline cannot consume a newer grace window")
    func oldIceDeadlineCannotCloseANewerDisconnectWindow() async throws {
        let agent = Self.makeHostAgent()
        await agent.beginConnectionLifecycle()
        await agent.setStateForTesting(.connected)

        let firstToken = await agent.noteIceDisconnectedForTesting(
            timeout: .seconds(30)
        )
        await agent.noteIceRecoveredForTesting()
        let secondToken = await agent.noteIceDisconnectedForTesting(
            timeout: .seconds(30)
        )

        await agent.fireIceDisconnectedDeadlineForTesting(token: firstToken)
        #expect(await agent.state == .connected)
        await agent.fireIceDisconnectedDeadlineForTesting(token: secondToken)
        #expect(await agent.state == .closed)
    }

    @Test("ICE checking does not strand an expired disconnect deadline")
    func checkingAfterDisconnectStillReleasesTheHostSlotAtDeadline() async throws {
        let agent = Self.makeHostAgent()
        await agent.beginConnectionLifecycle()
        await agent.setStateForTesting(.connected)

        let token = await agent.noteIceDisconnectedForTesting(
            timeout: .seconds(30)
        )
        await agent.applyIceStateForTesting(
            .checking,
            sequence: 1,
            timeout: .seconds(30)
        )
        await agent.fireIceDisconnectedDeadlineForTesting(token: token)

        #expect(await agent.state == .closed)
    }

    /// Regression guard for the `sshInstallStarted` reconnect-latch bug
    /// (W4 follow-up) — not a new spec ID. It protects the reconnect
    /// behavior already specified by REMOTE-2.1 (fresh authenticated
    /// attach after a reconnect) and REMOTE-3.2 (post-revoke teardown then
    /// reconnect), both of which silently depend on SSH actually
    /// re-installing on the new data channel.
    @Test
    func closeResetsTheInstallLatchSoAReconnectCanReinstallSSH() async throws {
        let agent = Self.makeHostAgent()

        // Simulate the first connection's data-channel-open path without
        // touching native WebRTC: `dataChannel` stays `nil`, so this sets
        // the latch and returns immediately.
        await agent.installSSHHandler()
        #expect(await agent.sshInstallStartedForTesting == true)

        await agent.close()

        // RED (pre-fix): this latch stayed `true` after close(), so a
        // reconnect's `installSSHHandler` call would hit the stale guard
        // and never install SSH on the new channel.
        #expect(await agent.sshInstallStartedForTesting == false)
    }

    /// Regression guard for the adopt-after-close interleaving. A queued
    /// install from the closed connection must be rejected at entry rather
    /// than latching shared state that the next connection inherits.
    @Test
    func staleInstallAfterCloseDoesNotLatchSharedState() async throws {
        let agent = Self.makeHostAgent()

        await agent.close()
        await agent.installSSHHandler()
        #expect(await agent.sshInstallStartedForTesting == false)

        await agent.beginConnectionLifecycle()
        #expect(await agent.sshInstallStartedForTesting == false)
    }

    /// Regression guard for the generation-guard fix — not a new spec ID.
    /// `WebRTCHostAgent` is a single process-wide instance reused for every
    /// device sequentially (`AppServices.hostAgent`); `installSSHHandler`'s
    /// `sshInstallStarted` reset above is what makes this reachable — it was
    /// impossible before that fix landed.
    ///
    /// `SSHConnectionRegistry.register`'s replace-path (see
    /// `SSHConnectionRegistry.register`'s doc comment) runs `await previous
    /// .close()`, where `previous.close` is the closure captured by the
    /// OLD connection's `registerAuthenticatedConnection` call. Because
    /// `self` is the SAME shared actor now serving the NEW (live)
    /// connection, an unguarded `previous.close()` tears down the new
    /// connection's state mid-lifetime — this reproduces that exact
    /// mechanism using only actor-level seams (`bumpConnectionGenerationForTesting`,
    /// `setStateForTesting`, `installSSHHandler`, `registerAuthenticatedConnection`
    /// — all bumped to `internal` for testing, matching the existing
    /// pattern in this file), no native WebRTC or NIOSSH involved.
    @Test
    func staleConnectionsCloseClosureDoesNotTearDownALiveReconnectedConnection() async throws {
        let registry = SSHConnectionRegistry()
        let store = TrustedPeerStore(directory: Self.tempDir())
        let deviceID = RemoteDeviceID.generate()
        try store.add(Self.makePeer(id: deviceID))
        let agent = Self.makeHostAgent(trustedPeerStore: store, registry: registry)

        // Connection A's lifecycle begins (mirrors what `acceptOffer` does
        // on every accepted offer — see its generation bump) and
        // authenticates, registering with the registry under generation 1.
        await agent.bumpConnectionGenerationForTesting()
        await agent.setStateForTesting(.connected)
        await agent.registerAuthenticatedConnection(deviceID: deviceID)
        #expect(await agent.state == .connected)

        // Connection B's lifecycle begins on the SAME shared agent — the
        // production scenario (one process-wide `WebRTCHostAgent` reused
        // sequentially). Bumping the generation to 2 and re-arming the SSH
        // install latch mirrors what a fresh `acceptOffer` +
        // `installSSHHandler` do for a genuinely new, live connection.
        await agent.bumpConnectionGenerationForTesting()
        await agent.setStateForTesting(.connected)
        await agent.installSSHHandler()
        #expect(await agent.sshInstallStartedForTesting == true)

        // B authenticates and registers for the SAME peer — a same-device
        // reconnect. `SSHConnectionRegistry.register`'s replace-path runs
        // `await previous.close()`, invoking A's STALE closure (captured at
        // generation 1) before B's own registration below is recorded.
        await agent.registerAuthenticatedConnection(deviceID: deviceID)

        // RED (pre-fix): A's stale closure called `self?.close()`
        // unconditionally, tearing down B's live state — `state` flipped to
        // `.closed` and the install latch reset to `false` — even though B
        // is the current, live connection and was never actually closed.
        #expect(await agent.state == .connected)
        #expect(await agent.sshInstallStartedForTesting == true)
    }

    @Test
    func closeDuringRegistrationDoesNotLeaveAPhantomRegistryEntry() async throws {
        let registry = SSHConnectionRegistry()
        let store = TrustedPeerStore(directory: Self.tempDir())
        let deviceID = RemoteDeviceID.generate()
        try store.add(Self.makePeer(id: deviceID))
        let agent = Self.makeHostAgent(trustedPeerStore: store, registry: registry)
        let gate = ReconnectRegistrationGate()

        _ = await registry.register(deviceID: deviceID) {
            await gate.wait()
        }
        await agent.bumpConnectionGenerationForTesting()
        await agent.setStateForTesting(.connected)

        let registration = Task {
            await agent.registerAuthenticatedConnection(deviceID: deviceID)
        }
        await gate.waitUntilArrived()

        await agent.close()
        await gate.open()
        await registration.value

        #expect(
            await registry.count == 0,
            "a registration that resumes after its agent closed must remove its own token"
        )
    }

    /// Isolated unit-level companion to the interaction test above: proves
    /// the guard's contract directly — a stale generation no-ops, the
    /// current generation still closes.
    @Test
    func closeIfGenerationNoOpsForStaleGenerationButClosesForCurrentGeneration() async throws {
        let agent = Self.makeHostAgent()
        await agent.bumpConnectionGenerationForTesting()
        let staleGeneration: UInt64 = 0
        await agent.setStateForTesting(.connected)

        await agent.close(ifGeneration: staleGeneration)
        #expect(await agent.state == .connected, "a stale generation must not tear down the current connection")

        let currentGeneration = await agent.connectionGenerationForTesting
        await agent.close(ifGeneration: currentGeneration)
        #expect(await agent.state == .closed, "the current generation must still close for real")
    }

    @Test
    func unauthenticatedConnectionDeadlineReleasesTheHostSlot() async throws {
        let agent = Self.makeHostAgent()
        await agent.beginConnectionLifecycle()
        await agent.setStateForTesting(.answering)
        await agent.startAuthenticationDeadlineForTesting(timeout: .milliseconds(20))

        for _ in 0..<100 {
            if await agent.state == .closed { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(
            await agent.state == .closed,
            "an offer that never reaches SSH authentication must not reserve the singleton host forever"
        )
    }

    /// VERIFY (task step 4): the generation guard must not break REMOTE-3.1/3.3
    /// revocation — an admin `revoke(deviceID:)` of the CURRENT connection
    /// captures the CURRENT generation at registration time, so the guard
    /// passes and the real close still runs.
    @Test
    func revokeOfTheCurrentConnectionStillClosesItBecauseTheGenerationMatches() async throws {
        let registry = SSHConnectionRegistry()
        let store = TrustedPeerStore(directory: Self.tempDir())
        let deviceID = RemoteDeviceID.generate()
        try store.add(Self.makePeer(id: deviceID))
        let agent = Self.makeHostAgent(trustedPeerStore: store, registry: registry)

        await agent.bumpConnectionGenerationForTesting()
        await agent.setStateForTesting(.connected)
        await agent.registerAuthenticatedConnection(deviceID: deviceID)
        #expect(await agent.state == .connected)

        await registry.revoke(deviceID: deviceID)

        #expect(await agent.state == .closed)
    }

    // MARK: - Fixtures

    private static func makeHostAgent(
        trustedPeerStore: TrustedPeerStore? = nil,
        registry: SSHConnectionRegistry = SSHConnectionRegistry()
    ) -> WebRTCHostAgent {
        WebRTCHostAgent(
            hostKey: Curve25519.Signing.PrivateKey(),
            trustedPeerStore: trustedPeerStore ?? TrustedPeerStore(directory: Self.tempDir()),
            streamFactory: { _ in fatalError("not expected: no data channel opens in this test") },
            panesStateSubscribe: { _ in PanesStateChannelHandler.Cancellable(cancel: {}) },
            paneControlMutator: { _ in fatalError("not expected: no data channel opens in this test") },
            displayOwnershipStore: SessionDisplayOwnershipStore(),
            sshConnectionRegistry: registry
        )
    }

    private static func makePeer(id: RemoteDeviceID) -> TrustedPeer {
        TrustedPeer(
            id: id,
            kind: .ipad,
            publicKey: try! RemoteIdentityPublicKey(
                rawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
            ),
            displayName: "test",
            capabilities: PairedDeviceCapabilities(
                terminalControl: .allowed,
                portTunnel: .disabled,
                screenView: .disabled,
                screenControl: .disabled
            ),
            pairedAt: Date(),
            lastSeenAt: nil
        )
    }

    private static func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-remote-2-1-hostagent-reconnect-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
