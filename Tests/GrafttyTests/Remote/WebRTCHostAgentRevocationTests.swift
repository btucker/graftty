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
/// The registration seam and trust recheck run without native WebRTC.
/// Constructing an agent leaves its lazy peer-connection factory untouched.
@Suite("WebRTCHostAgent re-verifies trust after the register Task-hop (REMOTE-3.1)")
struct WebRTCHostAgentRevocationTests {

    @Test("@spec PORTS-5.14: If a peer's authenticated identity or permissions change before SSH registration completes, then the application shall close the stale connection while preserving connections whose only changes are descriptive metadata.",
          arguments: ["port", "terminal", "key", "kind", "metadata"])
    func closesWhenAuthenticatedTrustChangesDuringRegistration(change: String) async throws {
        let directory = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrustedPeerStore(directory: directory)
        var peer = Self.makePeer(id: RemoteDeviceID.generate())
        peer.capabilities.portTunnel = .allowedLoopback
        try store.add(peer)
        var replacement = peer
        switch change {
        case "port": replacement.capabilities.portTunnel = .disabled
        case "terminal": replacement.capabilities.terminalControl = .disabled
        case "key", "kind":
            replacement = TrustedPeer(id: peer.id, kind: change == "kind" ? .mac : peer.kind,
                publicKey: change == "key" ? Self.makePeer(id: peer.id).publicKey : peer.publicKey,
                displayName: peer.displayName, capabilities: peer.capabilities,
                pairedAt: peer.pairedAt, lastSeenAt: peer.lastSeenAt)
        default:
            replacement.displayName = "Renamed device"
            replacement.lastSeenAt = Date()
        }
        let updatedPeer = replacement
        let registry = SSHConnectionRegistry()
        // Replacing a registry entry awaits its close callback. Change trust
        // during that suspension, after this connection captured its peer.
        await registry.register(deviceID: peer.id) {
            do { try store.update(updatedPeer) }
            catch { Issue.record("Could not update trust during registration: \(error)") }
        }
        let agent = Self.makeHostAgent(trustedPeerStore: store, registry: registry)
        await agent.beginConnectionLifecycle(clientDeviceID: peer.id)
        await agent.setStateForTesting(.connected)
        await agent.registerAuthenticatedConnection(deviceID: peer.id)
        #expect(await agent.state == (change == "metadata" ? .connected : .closed))
        await agent.close()
    }

    @Test
    func shouldNotCloseWhenPeerStillTrustedAfterRegister() async throws {
        let store = TrustedPeerStore(directory: Self.tempDir())
        let deviceID = RemoteDeviceID.generate()
        let peer = Self.makePeer(id: deviceID)
        try store.add(peer)

        let agent = Self.makeHostAgent(trustedPeerStore: store)

        #expect(await agent.shouldCloseAfterRegister(peer: peer) == false)
    }

    /// Regression guard protecting REMOTE-3.1's revocation guarantee
    /// against the register Task-hop race — not a distinct requirement of
    /// its own.
    @Test
    func shouldCloseWhenPeerWasRevokedDuringTheRegisterTaskHop() async throws {
        let store = TrustedPeerStore(directory: Self.tempDir())
        let deviceID = RemoteDeviceID.generate()
        let peer = Self.makePeer(id: deviceID)
        try store.add(peer)

        let agent = Self.makeHostAgent(trustedPeerStore: store)

        // Simulate the admin revoke landing during the Task-hop between
        // `onAuthenticated` firing and `registerAuthenticatedConnection`
        // resuming after `sshConnectionRegistry.register(...)`:
        // `PairedDevicesSection.remove`'s sequence removes the peer from
        // the trust store first.
        try store.remove(id: deviceID)

        #expect(await agent.shouldCloseAfterRegister(peer: peer) == true)
    }

    @Test
    func shouldCloseWhenDeviceWasNeverTrusted() async {
        let store = TrustedPeerStore(directory: Self.tempDir())
        let deviceID = RemoteDeviceID.generate()

        let agent = Self.makeHostAgent(trustedPeerStore: store)

        #expect(await agent.shouldCloseAfterRegister(peer: Self.makePeer(id: deviceID)) == true)
    }

    // MARK: - Fixtures

    private static func makeHostAgent(trustedPeerStore: TrustedPeerStore,
                                      registry: SSHConnectionRegistry = SSHConnectionRegistry()) -> WebRTCHostAgent {
        WebRTCHostAgent(
            hostKey: Curve25519.Signing.PrivateKey(),
            trustedPeerStore: trustedPeerStore,
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
            .appendingPathComponent("graftty-remote-3-1-hostagent-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
