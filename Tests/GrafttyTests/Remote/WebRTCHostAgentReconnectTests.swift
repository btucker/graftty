import CryptoKit
import Foundation
import Testing
@testable import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol

/// W4 follow-up bug: `installSSHHandler`'s `sshInstallStarted` guard is a
/// per-connection one-shot latch — it must flip back to `false` when a
/// connection tears down, so a RECONNECT's fresh data channel can install
/// SSH again. `close()` reset `sshTransport` / `authenticatedRegistration`
/// / `peerConnection` / `dataChannel` / `state` but NOT `sshInstallStarted`,
/// so a reconnect (`acceptOffer` after `close()`, which the busy-guard at
/// `acceptOffer`'s top explicitly permits from `.closed`) opened a new data
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

    /// Regression guard for the adopt-after-close interleaving — not a new
    /// spec ID. `peerConnection(_:didOpen:)` queues `adoptDataChannel` (and
    /// its `installSSHHandler`) as Tasks, so `close()` can run between the
    /// channel announcement and the install: the stale install then latches
    /// `sshInstallStarted = true` on the already-closed agent (its
    /// `dataChannel` is nil, so it latches and bails). The close-side reset
    /// has already run at that point, so only `acceptOffer`'s fresh-lifecycle
    /// re-arm (`beginConnectionLifecycle`) keeps the NEXT connection's
    /// install from hitting the stale latch and never attaching SSH.
    @Test
    func aFreshOfferReArmsTheInstallLatchAfterAStaleInstallLatchedPostClose() async throws {
        let agent = Self.makeHostAgent()

        await agent.close()
        // The stale install Task resumes on the closed agent and latches.
        await agent.installSSHHandler()
        #expect(await agent.sshInstallStartedForTesting == true)

        // Mirrors what every accepted offer does first (see `acceptOffer`).
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
