import CryptoKit
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import NIO
import NIOEmbedded
import NIOSSH
import XCTest

/// Tests for the capability check folded into `SSHUserAuthDelegate` per
/// R5's REMOTE-6.1/7.1 enforcement strategy.
final class SSHUserAuthCapabilityTests: XCTestCase {

    /// @spec REMOTE-6.1: A trusted peer with `terminalControl: .allowed`
    /// authenticates successfully.
    func testTrustedPeerWithCapAuthenticates() throws {
        let key = Curve25519.Signing.PrivateKey()
        let store = makeStore()
        try store.add(makePeer(key: key, terminalControl: .allowed))

        let outcome = try runUserAuth(key: key, store: store)
        XCTAssertTrue(isSuccess(outcome), "expected .success, got \(outcome)")
    }

    func testTrustedPeerWithCapRegistersActivePeer() throws {
        let key = Curve25519.Signing.PrivateKey()
        let peer = makePeer(key: key, terminalControl: .allowed)
        let store = makeStore()
        let registry = ActiveRemotePeerRegistry()
        try store.add(peer)

        let outcome = try runUserAuth(key: key, store: store, activePeerRegistry: registry)

        XCTAssertTrue(isSuccess(outcome), "expected .success, got \(outcome)")
        XCTAssertEqual(registry.entries(peerID: peer.id).map(\.fingerprint), [peer.fingerprint])
    }

    /// @spec REMOTE-7.1: When a client opens a channel with `channel_type: "pane_control"`
    /// over an authenticated `RemoteHostConnection`, the host shall accept the channel only
    /// when the requesting trusted peer holds the `terminal_control` capability.
    /// (Enforced at userauth: a peer with `terminalControl: .disabled` is rejected.)
    func testTrustedPeerWithoutCapRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let store = makeStore()
        try store.add(makePeer(key: key, terminalControl: .disabled))

        let outcome = try runUserAuth(key: key, store: store)
        XCTAssertTrue(isFailure(outcome), "expected .failure, got \(outcome)")
    }

    func testTrustedPeerWithoutCapDoesNotRegisterActivePeer() throws {
        let key = Curve25519.Signing.PrivateKey()
        let peer = makePeer(key: key, terminalControl: .disabled)
        let store = makeStore()
        let registry = ActiveRemotePeerRegistry()
        try store.add(peer)

        let outcome = try runUserAuth(key: key, store: store, activePeerRegistry: registry)

        XCTAssertTrue(isFailure(outcome), "expected .failure, got \(outcome)")
        XCTAssertTrue(registry.entries(peerID: peer.id).isEmpty)
    }

    /// An unpaired key fails userauth (existing R3 behavior, preserved).
    func testUnpairedKeyRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let store = makeStore()
        // No add — store is empty.

        let outcome = try runUserAuth(key: key, store: store)
        XCTAssertTrue(isFailure(outcome), "expected .failure, got \(outcome)")
    }

    func testUnpairedKeyDoesNotRegisterActivePeer() throws {
        let key = Curve25519.Signing.PrivateKey()
        let store = makeStore()
        let registry = ActiveRemotePeerRegistry()

        let outcome = try runUserAuth(key: key, store: store, activePeerRegistry: registry)

        XCTAssertTrue(isFailure(outcome), "expected .failure, got \(outcome)")
        XCTAssertTrue(registry.entries(peerID: RemoteDeviceID(value: "missing")).isEmpty)
        XCTAssertTrue(registry.entries.isEmpty)
    }

    // MARK: - helpers

    private func makeStore() -> TrustedPeerStore {
        TrustedPeerStore(directory: tempDir())
    }

    private func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-r5-userauth-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePeer(
        key: Curve25519.Signing.PrivateKey,
        terminalControl: PairedDeviceCapabilities.TerminalControl
    ) -> TrustedPeer {
        let publicKey = try! RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        return TrustedPeer(
            id: RemoteDeviceID(value: UUID().uuidString),
            kind: .iphone,
            publicKey: publicKey,
            displayName: "test",
            capabilities: PairedDeviceCapabilities(
                terminalControl: terminalControl,
                portTunnel: .disabled,
                screenView: .disabled,
                screenControl: .disabled
            ),
            pairedAt: Date(),
            lastSeenAt: nil
        )
    }

    /// Runs a single userauth roundtrip against a `SSHUserAuthDelegate` and
    /// returns the resulting outcome. `requestReceived` resolves its promise
    /// synchronously (no channel I/O involved), so `wait()` returns immediately
    /// without blocking any event loop thread.
    private func runUserAuth(
        key: Curve25519.Signing.PrivateKey,
        store: TrustedPeerStore,
        activePeerRegistry: ActiveRemotePeerRegistry? = nil
    ) throws -> NIOSSHUserAuthenticationOutcome {
        let loop = EmbeddedEventLoop()
        defer { try! loop.syncShutdownGracefully() }
        let delegate = SSHUserAuthDelegate(
            store: store,
            activePeerRegistry: activePeerRegistry,
            closeActiveTransport: {}
        )
        let publicKey = NIOSSHPrivateKey(ed25519Key: key).publicKey
        let request = NIOSSHUserAuthenticationRequest(
            username: "graftty",
            serviceName: "ssh-connection",
            request: .publicKey(.init(publicKey: publicKey))
        )
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOutcome.self)
        delegate.requestReceived(request: request, responsePromise: promise)
        return try promise.futureResult.wait()
    }

    private func isSuccess(_ outcome: NIOSSHUserAuthenticationOutcome) -> Bool {
        if case .success = outcome { return true }
        return false
    }

    private func isFailure(_ outcome: NIOSSHUserAuthenticationOutcome) -> Bool {
        if case .failure = outcome { return true }
        return false
    }
}
