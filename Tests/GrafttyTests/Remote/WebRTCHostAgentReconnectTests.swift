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

    // MARK: - Fixtures

    private static func makeHostAgent() -> WebRTCHostAgent {
        WebRTCHostAgent(
            hostKey: Curve25519.Signing.PrivateKey(),
            trustedPeerStore: TrustedPeerStore(directory: Self.tempDir()),
            streamFactory: { _ in fatalError("not expected: no data channel opens in this test") },
            panesStateSubscribe: { _ in PanesStateChannelHandler.Cancellable(cancel: {}) },
            paneControlMutator: { _ in fatalError("not expected: no data channel opens in this test") },
            displayOwnershipStore: SessionDisplayOwnershipStore()
        )
    }

    private static func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-remote-2-1-hostagent-reconnect-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
