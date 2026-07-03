import CryptoKit
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import NIO
import NIOEmbedded
import NIOSSH
import XCTest

/// REMOTE-2.1's host-side proof.
///
/// The end-to-end nuance — a real WebRTC reconnect producing a SECOND
/// full SSH userauth before any channel opens — is proven at the
/// mobile/coordinator layer by `RemoteConnectionReconnectTests
/// .invalidateThenReconnectProducesASecondFullUserauth` (tagged
/// spec IPAD-5.2, a DIFFERENT requirement that same test happens to
/// also exercise — a spec ID lives in one behavioral location, so this
/// file cannot re-tag that test with REMOTE-2.1 too). That test needs a
/// real `RTCPeerConnectionFactory`/`RTCPeerConnection` and MUST NOT run
/// on headless mac CI (native libwebrtc init hangs the runner — the W3
/// postmortem cost two CI-fix rounds learning this).
///
/// This file instead proves REMOTE-2.1's essence at the host's SSH
/// userauth boundary, entirely on `EmbeddedEventLoop`s — no WebRTC, no
/// native libwebrtc:
///
///   - SSH has no session resumption. `SSHServerSetup.makeHandler`
///     constructs a brand-new `SSHUserAuthDelegate` (over the shared
///     `TrustedPeerStore`) for every inbound connection — see that
///     type's single call site. A reconnect is therefore, structurally,
///     a SECOND, wholly independent `SSHUserAuthDelegate` instance
///     deciding its own `NIOSSHUserAuthenticationOutcome` from scratch.
///   - NIOSSH refuses every `SSH_MSG_CHANNEL_OPEN` — and therefore never
///     installs `TerminalSessionHandler`, the only handler through which
///     any byte ever reaches the PTY (see `TerminalSessionHandlerTests`)
///     — until userauth on THAT connection has independently succeeded.
///     `SSHUserAuthCapabilityTests` already covers the single-connection
///     "no capability -> no auth -> no channel" gate.
///
/// What's unique to REMOTE-2.1 is the RECONNECT nuance: attach #2 must
/// not inherit, cache, or skip past attach #1's outcome. The tests below
/// drive two independent delegate instances (mirroring two independent
/// connections) against a shared store and show that (a) a trust change
/// made between attaches takes effect on attach #2 exactly as it would
/// for a first-ever connection, and (b) even when trust is unchanged,
/// attach #2 runs its OWN fresh handshake rather than piggybacking on
/// attach #1's.
final class SSHReconnectFreshAuthTests: XCTestCase {

    /// @spec REMOTE-2.1: When a remote transport reconnects, the host shall require a fresh authenticated attach handshake before writing any bytes to the PTY.
    func testReconnectAfterRevocationDoesNotInheritFirstAttachsSuccess() throws {
        let key = Curve25519.Signing.PrivateKey()
        let store = makeStore()
        let peer = makePeer(key: key, terminalControl: .allowed)
        try store.add(peer)

        // Attach #1 (first connection): a fresh delegate + fresh loop,
        // exactly what `SSHServerSetup.makeHandler` builds for an inbound
        // connection.
        let firstAuthenticated = AuthenticatedIDBox()
        let firstOutcome = try runUserAuth(key: key, store: store) { firstAuthenticated.set($0) }
        XCTAssertTrue(isSuccess(firstOutcome), "attach #1 must authenticate")
        XCTAssertEqual(firstAuthenticated.value, peer.id, "onAuthenticated must fire for attach #1")

        // Revoke trust between attaches — the peer became untrusted while
        // disconnected. If a reconnect's userauth reused/cached attach
        // #1's outcome instead of requiring a genuinely fresh one, this
        // revocation would have no effect on attach #2.
        try store.remove(id: peer.id)

        // Attach #2 ("the reconnect"): a SECOND, wholly independent
        // `SSHUserAuthDelegate` on a SECOND `EmbeddedEventLoop` — no
        // shared state with attach #1 beyond the store — mirroring a
        // brand-new WebRTC data channel standing up a brand-new
        // NIOSSHHandler + delegate.
        let secondAuthenticated = AuthenticatedIDBox()
        let secondOutcome = try runUserAuth(key: key, store: store) { secondAuthenticated.set($0) }
        XCTAssertTrue(
            isFailure(secondOutcome),
            "reconnect must require its own fresh authenticated attach; it must not honor attach #1's now-stale success"
        )
        XCTAssertNil(
            secondAuthenticated.value,
            "onAuthenticated (the gate before any channel — and therefore any PTY byte — can open) must not fire for a reconnect whose own fresh userauth fails"
        )
    }

    /// Positive-path counterpart: even when trust is unchanged, a
    /// reconnect must independently re-run userauth rather than treat
    /// attach #1's success as still valid — proven by requiring
    /// `onAuthenticated` to fire a SECOND time, once per attach, not once
    /// total.
    func testReconnectWithUnchangedTrustStillPerformsItsOwnFreshUserauth() throws {
        let key = Curve25519.Signing.PrivateKey()
        let store = makeStore()
        let peer = makePeer(key: key, terminalControl: .allowed)
        try store.add(peer)

        let firstCallCount = CallCounterBox()
        let firstOutcome = try runUserAuth(key: key, store: store) { _ in firstCallCount.increment() }
        XCTAssertTrue(isSuccess(firstOutcome), "attach #1 must authenticate")
        XCTAssertEqual(firstCallCount.value, 1)

        // Reconnect: brand-new delegate + brand-new loop, trust unchanged.
        let secondCallCount = CallCounterBox()
        let secondOutcome = try runUserAuth(key: key, store: store) { _ in secondCallCount.increment() }
        XCTAssertTrue(isSuccess(secondOutcome), "reconnect with unchanged trust must still succeed on its own fresh handshake")
        XCTAssertEqual(secondCallCount.value, 1, "attach #2's onAuthenticated must fire independently of attach #1's")
    }

    // MARK: - helpers

    private func makeStore() -> TrustedPeerStore {
        TrustedPeerStore(directory: tempDir())
    }

    private func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-remote-2-1-reconnect-\(UUID().uuidString)")
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

    /// Runs a single userauth roundtrip against a FRESH
    /// `SSHUserAuthDelegate` on a FRESH `EmbeddedEventLoop` — i.e. one
    /// "attach." Each call stands up entirely new delegate + loop
    /// instances (never reused across calls in this file), mirroring how
    /// `SSHServerSetup.makeHandler` builds a new `SSHUserAuthDelegate`
    /// per inbound connection. `requestReceived` resolves its promise
    /// synchronously (no channel I/O involved), so `wait()` returns
    /// immediately without blocking any event-loop thread.
    private func runUserAuth(
        key: Curve25519.Signing.PrivateKey,
        store: TrustedPeerStore,
        onAuthenticated: @escaping @Sendable (RemoteDeviceID) -> Void = { _ in }
    ) throws -> NIOSSHUserAuthenticationOutcome {
        let loop = EmbeddedEventLoop()
        defer { try! loop.syncShutdownGracefully() }
        let delegate = SSHUserAuthDelegate(store: store, onAuthenticated: onAuthenticated)
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

/// Thread-safe capture cell for `onAuthenticated`'s `RemoteDeviceID` — the
/// callback can fire from a different thread than the test body per its
/// documented contract, so a plain `var` capture is a Swift 6 data race.
private final class AuthenticatedIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: RemoteDeviceID?

    var value: RemoteDeviceID? {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func set(_ id: RemoteDeviceID) {
        lock.lock(); defer { lock.unlock() }
        _value = id
    }
}

/// Thread-safe call counter, same rationale as `AuthenticatedIDBox`.
private final class CallCounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}
