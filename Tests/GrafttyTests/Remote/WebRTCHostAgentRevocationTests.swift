import CryptoKit
import Foundation
import Testing
@testable import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol

/// REMOTE-3.1 revocation (W4 review finding 3): `registerAuthenticatedConnection`
/// awaits `sshConnectionRegistry.register(...)` before recording
/// `authenticatedRegistration` — that `await` is a Task-hop away from
/// `onAuthenticated` firing (see the call site's comment in
/// `WebRTCHostAgent.installSSHHandler`), which leaves a window where an
/// admin can revoke the peer (removing it from `TrustedPeerStore`) before
/// registration lands. Without a post-register recheck, that window would
/// leave a live, authenticated connection open for a peer that's no longer
/// trusted.
///
/// `registerAuthenticatedConnection` itself can't be driven end-to-end here
/// without going through `installSSHHandler`, which requires a real
/// `RTCDataChannel` (native libwebrtc — forbidden in this suite, see
/// `SignalingHandlerOutcomeTests` for the CI-hang history). The fix is
/// instead verified at the unit the fix actually lives in:
/// `shouldCloseAfterRegister(deviceID:)`, the extracted, synchronous,
/// WebRTC-free trust-store recheck that `registerAuthenticatedConnection`
/// calls immediately after `register` returns. Constructing a
/// `WebRTCHostAgent` is safe without native WebRTC — its `factory` is lazy
/// and untouched until `acceptOffer` runs (see `WebRTCHostAgent.factory`'s
/// doc comment) — so this suite exercises `shouldCloseAfterRegister`
/// directly through a real agent instance and a real, file-backed
/// `TrustedPeerStore`, exactly as production wires them.
@Suite("WebRTCHostAgent re-verifies trust after the register Task-hop (REMOTE-3.1)")
struct WebRTCHostAgentRevocationTests {

    @Test
    func shouldNotCloseWhenPeerStillTrustedAfterRegister() async throws {
        let store = TrustedPeerStore(directory: Self.tempDir())
        let deviceID = RemoteDeviceID.generate()
        try store.add(Self.makePeer(id: deviceID))

        let agent = Self.makeHostAgent(trustedPeerStore: store)

        #expect(await agent.shouldCloseAfterRegister(deviceID: deviceID) == false)
    }

    /// Regression guard protecting REMOTE-3.1's revocation guarantee
    /// against the register Task-hop race — not a distinct requirement of
    /// its own.
    @Test
    func shouldCloseWhenPeerWasRevokedDuringTheRegisterTaskHop() async throws {
        let store = TrustedPeerStore(directory: Self.tempDir())
        let deviceID = RemoteDeviceID.generate()
        try store.add(Self.makePeer(id: deviceID))

        let agent = Self.makeHostAgent(trustedPeerStore: store)

        // Simulate the admin revoke landing during the Task-hop between
        // `onAuthenticated` firing and `registerAuthenticatedConnection`
        // resuming after `sshConnectionRegistry.register(...)`:
        // `PairedDevicesSection.remove`'s sequence removes the peer from
        // the trust store first.
        try store.remove(id: deviceID)

        #expect(await agent.shouldCloseAfterRegister(deviceID: deviceID) == true)
    }

    @Test
    func shouldCloseWhenDeviceWasNeverTrusted() async {
        let store = TrustedPeerStore(directory: Self.tempDir())
        let deviceID = RemoteDeviceID.generate()

        let agent = Self.makeHostAgent(trustedPeerStore: store)

        #expect(await agent.shouldCloseAfterRegister(deviceID: deviceID) == true)
    }

    // MARK: - Fixtures

    private static func makeHostAgent(trustedPeerStore: TrustedPeerStore) -> WebRTCHostAgent {
        WebRTCHostAgent(
            hostKey: Curve25519.Signing.PrivateKey(),
            trustedPeerStore: trustedPeerStore,
            streamFactory: { _ in fatalError("not expected: no data channel opens in this test") },
            panesStateSubscribe: { _ in PanesStateChannelHandler.Cancellable(cancel: {}) },
            paneControlMutator: { _ in fatalError("not expected: no data channel opens in this test") },
            displayOwnershipStore: SessionDisplayOwnershipStore()
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
            .appendingPathComponent("graftty-remote-3-1-hostagent-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
