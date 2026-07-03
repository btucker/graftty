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
        try store.add(SSHUserAuthTestSupport.makePeer(key: key, terminalControl: .allowed))

        let outcome = try SSHUserAuthTestSupport.runUserAuth(key: key, store: store)
        XCTAssertTrue(SSHUserAuthTestSupport.isSuccess(outcome), "expected .success, got \(outcome)")
    }

    /// @spec REMOTE-7.1: When a client opens a channel with `channel_type: "pane_control"`
    /// over an authenticated `RemoteHostConnection`, the host shall accept the channel only
    /// when the requesting trusted peer holds the `terminal_control` capability.
    /// (Enforced at userauth: a peer with `terminalControl: .disabled` is rejected.)
    func testTrustedPeerWithoutCapRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let store = makeStore()
        try store.add(SSHUserAuthTestSupport.makePeer(key: key, terminalControl: .disabled))

        let outcome = try SSHUserAuthTestSupport.runUserAuth(key: key, store: store)
        XCTAssertTrue(SSHUserAuthTestSupport.isFailure(outcome), "expected .failure, got \(outcome)")
    }

    /// An unpaired key fails userauth (existing R3 behavior, preserved).
    func testUnpairedKeyRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let store = makeStore()
        // No add — store is empty.

        let outcome = try SSHUserAuthTestSupport.runUserAuth(key: key, store: store)
        XCTAssertTrue(SSHUserAuthTestSupport.isFailure(outcome), "expected .failure, got \(outcome)")
    }

    // MARK: - helpers

    private func makeStore() -> TrustedPeerStore {
        SSHUserAuthTestSupport.makeStore(prefix: "graftty-r5-userauth")
    }
}
