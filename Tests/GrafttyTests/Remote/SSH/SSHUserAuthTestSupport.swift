import CryptoKit
import Foundation
@testable import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import NIOCore
import NIOEmbedded
import NIOSSH

/// Shared fixtures for the SSH userauth spec suites (REMOTE-2.1,
/// REMOTE-3.1/3.2, REMOTE-6.1/7.1, REMOTE-7.6): `SSHUserAuthCapabilityTests`,
/// `SSHReconnectFreshAuthTests`, and `SSHRevocationCascadeTests` were each
/// hand-rolling the same `TrustedPeerStore` temp-dir fixture, `TrustedPeer`
/// factory, and `SSHUserAuthDelegate` roundtrip driver — extracted here so
/// a change to one (e.g. a new `TrustedPeer` field) only needs updating in
/// one place.
enum SSHUserAuthTestSupport {
    /// Creates a fresh, empty directory under the system temp dir for a
    /// file-backed `TrustedPeerStore`. `prefix` keeps each suite's temp
    /// dirs distinguishable when debugging a leftover directory.
    static func tempDir(prefix: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeStore(prefix: String) -> TrustedPeerStore {
        TrustedPeerStore(directory: tempDir(prefix: prefix))
    }

    /// Builds a `TrustedPeer` around `key`'s public key. Every parameter
    /// besides `key` has a default matching the most common shape across
    /// the suites that used to hand-roll this literal (an `.iphone` with
    /// `terminalControl: .allowed`); callers needing an `.ipad` or a
    /// caller-supplied `id` (e.g. to correlate with `onAuthenticated`'s
    /// captured device ID) override just that parameter.
    static func makePeer(
        id: RemoteDeviceID = .generate(),
        key: Curve25519.Signing.PrivateKey,
        kind: RemoteDeviceKind = .iphone,
        terminalControl: PairedDeviceCapabilities.TerminalControl = .allowed
    ) -> TrustedPeer {
        TrustedPeer(
            id: id,
            kind: kind,
            publicKey: try! RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation),
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
    /// returns the outcome. `requestReceived` resolves its promise
    /// synchronously (no channel I/O involved), so `wait()` returns
    /// immediately without blocking any event loop thread.
    ///
    /// Pass `loop` to drive the request on an `EmbeddedEventLoop` a caller
    /// already owns (e.g. one also pumping a live SSH handshake via
    /// `interactInMemory`); omitted, a fresh loop is created and
    /// synchronously shut down before returning — safe here because this
    /// function is itself non-`async`, so callers invoking it from an
    /// `async` test body aren't calling `syncShutdownGracefully()`
    /// directly from an async context.
    static func runUserAuth(
        key: Curve25519.Signing.PrivateKey,
        store: TrustedPeerStore,
        loop: EmbeddedEventLoop? = nil,
        onAuthenticated: @escaping @Sendable (RemoteDeviceID) -> Void = { _ in }
    ) throws -> NIOSSHUserAuthenticationOutcome {
        let ownedLoop = loop == nil ? EmbeddedEventLoop() : nil
        defer { if let ownedLoop { try! ownedLoop.syncShutdownGracefully() } }
        let activeLoop = loop ?? ownedLoop!

        let delegate = SSHUserAuthDelegate(store: store, onAuthenticated: onAuthenticated)
        let publicKey = NIOSSHPrivateKey(ed25519Key: key).publicKey
        let request = NIOSSHUserAuthenticationRequest(
            username: "graftty",
            serviceName: "ssh-connection",
            request: .publicKey(.init(publicKey: publicKey))
        )
        let promise = activeLoop.makePromise(of: NIOSSHUserAuthenticationOutcome.self)
        delegate.requestReceived(request: request, responsePromise: promise)
        return try promise.futureResult.wait()
    }

    static func isSuccess(_ outcome: NIOSSHUserAuthenticationOutcome) -> Bool {
        if case .success = outcome { return true }
        return false
    }

    static func isFailure(_ outcome: NIOSSHUserAuthenticationOutcome) -> Bool {
        if case .failure = outcome { return true }
        return false
    }

    /// Hand-pumps outbound bytes between two `EmbeddedChannel`s sharing one
    /// `EmbeddedEventLoop` until neither side has anything left to send —
    /// the same technique swift-nio-ssh's own
    /// `BackToBackEmbeddedChannel.interactInMemory()` uses to drive a real
    /// SSH handshake between two in-process endpoints without any real
    /// socket or (in our case) any WebRTC data channel.
    static func interactInMemory(loop: EmbeddedEventLoop, client: EmbeddedChannel, server: EmbeddedChannel) throws {
        var workToDo = true
        while workToDo {
            workToDo = false
            loop.run()
            if let clientMsg = try client.readOutbound(as: IOData.self) {
                try server.writeInbound(clientMsg)
                workToDo = true
            }
            if let serverMsg = try server.readOutbound(as: IOData.self) {
                try client.writeInbound(serverMsg)
                workToDo = true
            }
        }
    }
}
