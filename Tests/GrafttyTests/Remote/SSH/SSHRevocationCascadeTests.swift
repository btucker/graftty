import CryptoKit
import Foundation
@testable import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing

/// WebRTC-free proof of the cascade `SSHConnectionRegistry`'s revocation
/// closure relies on: `WebRTCHostAgent.close()` closes its
/// `sshTransport`, which (via `SSHNIOTransport.close()`) closes the SSH
/// parent channel. This suite proves that closing an SSH parent channel
/// tears down every open child channel on it — independent of
/// `WebRTCHostAgent`, `SSHNIOTransport`, and any WebRTC/libwebrtc type.
///
/// Two plain `EmbeddedChannel`s share one `EmbeddedEventLoop` and are
/// bridged by hand-pumping outbound bytes from one into the other's
/// inbound side (`interactInMemory`, mirrored from swift-nio-ssh's own
/// `BackToBackEmbeddedChannel` end-to-end test harness) — a real client
/// + server SSH handshake needs two live, byte-exchanging endpoints, and
/// this gives that synchronously with zero native WebRTC involvement.
/// The server side uses the PRODUCTION `SSHServerSetup.makeHandler`
/// factory (same one `WebRTCHostAgent.installSSHHandler` calls); the
/// client side is a minimal test-only `NIOSSHHandler` offering a single
/// trusted key, since the client's identity isn't production code here.
///
/// CI-hang constraint: this suite MUST NOT construct `RTCPeerConnection`
/// / `RTCPeerConnectionFactory`, call `WebRTCHostAgent.acceptOffer`, or
/// construct `SSHNIOTransport` — any of those touch native libwebrtc,
/// which hangs the headless mac CI runner (see `WebRTCHostAgent.factory`'s
/// lazy-init comment and `SignalingHandlerOutcomeTests`).
@Suite("SSH parent-channel close cascades to open child channels (REMOTE-3.1 mechanism)")
struct SSHRevocationCascadeTests {

    @Test
    func closingParentChannelClosesOpenChildChannel() throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()

        let store = TrustedPeerStore(directory: Self.tempDir())
        try store.add(SSHUserAuthTestSupport.makePeer(key: clientKey, kind: .ipad))

        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let client = EmbeddedChannel(loop: loop)
        let server = EmbeddedChannel(loop: loop)

        // Production factory — the exact call `WebRTCHostAgent.installSSHHandler`
        // makes, just pointed at a plain `EmbeddedChannel` instead of
        // `SSHNIOTransport.channel`.
        let serverChildBox = ChildChannelBox()
        let serverHandler = SSHServerSetup.makeHandler(
            hostKey: serverKey,
            trustedPeerStore: store,
            allocator: server.allocator,
            inboundChildChannelInitializer: { child, channelType in
                guard case .session = channelType else {
                    return child.eventLoop.makeFailedFuture(TestError.unexpectedChannelType)
                }
                serverChildBox.channel = child
                return child.eventLoop.makeSucceededVoidFuture()
            }
        )
        try server.pipeline.syncOperations.addHandler(serverHandler)

        // Test-only client: offers the trusted key, accepts any host key
        // (host-key pinning is exercised elsewhere — this suite is about
        // the parent→child close cascade, not identity verification).
        let clientHandler = NIOSSHHandler(
            role: .client(
                SSHClientConfiguration(
                    userAuthDelegate: SingleOfferClientAuth(key: clientKey),
                    serverAuthDelegate: AcceptAllHostKeys()
                )
            ),
            allocator: client.allocator,
            inboundChildChannelInitializer: nil
        )
        try client.pipeline.syncOperations.addHandler(clientHandler)

        // `EmbeddedChannel` only fires `channelActive` (which kicks off
        // the SSH version exchange) on `connect`.
        try client.connect(to: SocketAddress(unixDomainSocketPath: "/fake")).wait()
        try server.connect(to: SocketAddress(unixDomainSocketPath: "/fake")).wait()

        try SSHUserAuthTestSupport.interactInMemory(loop: loop, client: client, server: server)

        // Open a session child channel from the client and pump until
        // the server's `inboundChildChannelInitializer` has run.
        var clientChild: Channel?
        let clientSSHHandler = try client.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
        clientSSHHandler.createChannel(channelType: .session) { channel, channelType in
            guard case .session = channelType else {
                return channel.eventLoop.makeFailedFuture(TestError.unexpectedChannelType)
            }
            clientChild = channel
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        try SSHUserAuthTestSupport.interactInMemory(loop: loop, client: client, server: server)

        let serverChild = try #require(serverChildBox.channel, "server never opened the session child channel")
        #expect(clientChild?.isActive == true)
        #expect(serverChild.isActive == true)

        // The cascade under test: close the SERVER's own parent channel
        // — exactly what `SSHNIOTransport.close()` does when
        // `WebRTCHostAgent.close()` runs (itself the revocation
        // registry's close closure). No interaction with the client is
        // needed for THIS assertion — the cascade is local to whichever
        // side closes its own parent channel.
        try server.close().wait()

        #expect(serverChild.isActive == false)
    }

    /// REMOTE-3.1 (see the `@Test` title below for the verbatim EARS text).
    ///
    /// End-to-end at the registry+SSH+userauth layer (the
    /// Settings-UI-triggers-revoke layer is already owned by REMOTE-3.3's
    /// `PairedDevicesSectionTests`):
    ///   - close half: registers the SAME close-closure shape
    ///     `WebRTCHostAgent.registerAuthenticatedConnection` installs
    ///     (`SSHConnectionRegistry.register` → closes the SSH parent
    ///     channel) under `SSHConnectionRegistry`, then `revoke`s it and
    ///     asserts the open child channel goes inactive — the exact
    ///     parent→child cascade `closingParentChannelClosesOpenChildChannel`
    ///     above proves, now driven through the real registry instead of a
    ///     bare `server.close()`.
    ///   - reject half: mirrors `SSHUserAuthCapabilityTests`' delegate-on-
    ///     EmbeddedEventLoop pattern — after `TrustedPeerStore.remove`
    ///     (the same call `PairedDevicesSection.remove` makes right before
    ///     `revoke`), a fresh `SSHUserAuthDelegate.requestReceived` for the
    ///     revoked peer's key fails.
    @Test("""
@spec REMOTE-3.1: If a trusted peer is revoked on the host, then all active secure channels from that peer shall close and future attach requests from that peer shall be rejected.
""")
    func revokedPeerChannelsCloseAndFutureAttachRejected() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerID = RemoteDeviceID.generate()

        let store = TrustedPeerStore(directory: Self.tempDir())
        try store.add(SSHUserAuthTestSupport.makePeer(id: peerID, key: clientKey, kind: .ipad))

        let loop = EmbeddedEventLoop()
        // `syncShutdownGracefully()` is unavailable in an async context
        // (Swift 6 forbids the blocking `wait()` it's built on); the
        // callback-based overload shuts the loop down without blocking.
        defer { loop.shutdownGracefully { _ in } }
        let client = EmbeddedChannel(loop: loop)
        let server = EmbeddedChannel(loop: loop)

        // Mirrors `WebRTCHostAgent.installSSHHandler`'s `onAuthenticated`
        // wiring: capture the peer's `RemoteDeviceID` synchronously, the
        // same moment `registerAuthenticatedConnection` would fire from.
        let authenticatedDeviceIDBox = DeviceIDBox()
        let serverChildBox = ChildChannelBox()
        let serverHandler = SSHServerSetup.makeHandler(
            hostKey: serverKey,
            trustedPeerStore: store,
            allocator: server.allocator,
            onAuthenticated: { deviceID in authenticatedDeviceIDBox.value = deviceID },
            inboundChildChannelInitializer: { child, channelType in
                guard case .session = channelType else {
                    return child.eventLoop.makeFailedFuture(TestError.unexpectedChannelType)
                }
                serverChildBox.channel = child
                return child.eventLoop.makeSucceededVoidFuture()
            }
        )
        try server.pipeline.syncOperations.addHandler(serverHandler)

        let clientHandler = NIOSSHHandler(
            role: .client(
                SSHClientConfiguration(
                    userAuthDelegate: SingleOfferClientAuth(key: clientKey),
                    serverAuthDelegate: AcceptAllHostKeys()
                )
            ),
            allocator: client.allocator,
            inboundChildChannelInitializer: nil
        )
        try client.pipeline.syncOperations.addHandler(clientHandler)

        try await client.connect(to: SocketAddress(unixDomainSocketPath: "/fake")).get()
        try await server.connect(to: SocketAddress(unixDomainSocketPath: "/fake")).get()
        try SSHUserAuthTestSupport.interactInMemory(loop: loop, client: client, server: server)

        var clientChild: Channel?
        let clientSSHHandler = try client.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
        clientSSHHandler.createChannel(channelType: .session) { channel, channelType in
            guard case .session = channelType else {
                return channel.eventLoop.makeFailedFuture(TestError.unexpectedChannelType)
            }
            clientChild = channel
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        try SSHUserAuthTestSupport.interactInMemory(loop: loop, client: client, server: server)

        let serverChild = try #require(serverChildBox.channel, "server never opened the session child channel")
        let deviceID = try #require(authenticatedDeviceIDBox.value, "userauth never authenticated the peer")
        #expect(clientChild?.isActive == true)
        #expect(serverChild.isActive == true)

        // All handshake byte-pumping is done above; everything from here is
        // sequential `await`s with no concurrent `loop.run()` polling racing
        // it, so the actor hop through `SSHConnectionRegistry` touching
        // `server` (an `EmbeddedChannel`) once, synchronously, inside
        // `close()` cannot collide with another thread the way
        // `PaneControlChannelHandlerTests`' background-Task-vs-busy-poll
        // pattern can — there IS no concurrent poller here to race against.
        let registry = SSHConnectionRegistry()
        await registry.register(deviceID: deviceID) {
            try? await server.close().get()
        }

        // Close half: mirrors `PairedDevicesSection.remove`'s sequence —
        // remove from the trust store, THEN revoke the live connection.
        try store.remove(id: deviceID)
        await registry.revoke(deviceID: deviceID)

        #expect(serverChild.isActive == false, "revocation must close the peer's open child channel")

        // Reject half: a subsequent userauth attempt for the SAME (now
        // untrusted) fingerprint must fail. `SSHUserAuthDelegate` enforces
        // this by exclusion — a peer absent from `TrustedPeerStore` cannot
        // authenticate, so it cannot open any future channel either.
        let outcome = try SSHUserAuthTestSupport.runUserAuth(key: clientKey, store: store, loop: loop)
        guard case .failure = outcome else {
            Issue.record("expected revoked peer's userauth to fail, got \(outcome)")
            return
        }
    }

    /// REMOTE-7.6 (see the `@Test` title below for the verbatim EARS text).
    ///
    /// Same shape as `revokedPeerChannelsCloseAndFutureAttachRejected` above,
    /// but the open child channel is specifically routed to a `pane_control`
    /// subsystem (`SSHChannelTypeNames.paneControl`) via the PRODUCTION
    /// `SubsystemDispatcher` — the same dispatcher
    /// `WebRTCHostAgent.installSSHHandler`'s `inboundChildChannelInitializer`
    /// installs — rather than left as a bare session channel. The reject
    /// half is the same userauth-exclusion mechanism as REMOTE-3.1: no
    /// channel-open-time capability check exists for `pane_control` (see
    /// `SSHUserAuthDelegate`'s doc comment — REMOTE-6.1/7.1 enforcement is
    /// folded into userauth for every R5-scope channel type), so a revoked
    /// peer failing userauth is sufficient to reject a subsequent
    /// `pane_control` open request too.
    @Test("""
@spec REMOTE-7.6: If a trusted peer is revoked while a `pane_control` channel is open, the channel shall close and subsequent open requests from the revoked peer shall be rejected.
""")
    func revokedPeerPaneControlChannelClosesAndReopenRejected() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerID = RemoteDeviceID.generate()

        let store = TrustedPeerStore(directory: Self.tempDir())
        try store.add(SSHUserAuthTestSupport.makePeer(id: peerID, key: clientKey, kind: .ipad))

        let loop = EmbeddedEventLoop()
        // See `revokedPeerChannelsCloseAndFutureAttachRejected` above for
        // why the callback-based overload is used instead of
        // `syncShutdownGracefully()` here.
        defer { loop.shutdownGracefully { _ in } }
        let client = EmbeddedChannel(loop: loop)
        let server = EmbeddedChannel(loop: loop)

        let authenticatedDeviceIDBox = DeviceIDBox()
        let serverChildBox = ChildChannelBox()
        let serverHandler = SSHServerSetup.makeHandler(
            hostKey: serverKey,
            trustedPeerStore: store,
            allocator: server.allocator,
            onAuthenticated: { deviceID in authenticatedDeviceIDBox.value = deviceID },
            inboundChildChannelInitializer: { child, channelType in
                guard case .session = channelType else {
                    return child.eventLoop.makeFailedFuture(TestError.unexpectedChannelType)
                }
                serverChildBox.channel = child
                // Production wiring (`WebRTCHostAgent.installSSHHandler`):
                // every inbound session child channel gets a
                // `SubsystemDispatcher` so it can be routed to
                // `pane-control@graftty.dev` by a subsystem request.
                // `streamFactory` is never invoked on this path (we route
                // to pane-control, not a terminal session) — asserting
                // that would be a bug, hence the fatal error rather than a
                // silent fallback.
                return child.eventLoop.makeCompletedFuture {
                    let dispatcher = SubsystemDispatcher(
                        streamFactory: { _ in fatalError("terminal-session path not exercised by this test") },
                        panesStateSubscribe: { _ in PanesStateChannelHandler.Cancellable(cancel: {}) },
                        paneControlMutator: { _ in .ok },
                        ownershipStore: SessionDisplayOwnershipStore(),
                        ownershipBroadcaster: DisplayOwnershipBroadcaster(),
                        deviceIDProvider: { authenticatedDeviceIDBox.value }
                    )
                    try child.pipeline.syncOperations.addHandler(dispatcher)
                }
            }
        )
        try server.pipeline.syncOperations.addHandler(serverHandler)

        let clientHandler = NIOSSHHandler(
            role: .client(
                SSHClientConfiguration(
                    userAuthDelegate: SingleOfferClientAuth(key: clientKey),
                    serverAuthDelegate: AcceptAllHostKeys()
                )
            ),
            allocator: client.allocator,
            inboundChildChannelInitializer: nil
        )
        try client.pipeline.syncOperations.addHandler(clientHandler)

        try await client.connect(to: SocketAddress(unixDomainSocketPath: "/fake")).get()
        try await server.connect(to: SocketAddress(unixDomainSocketPath: "/fake")).get()
        try SSHUserAuthTestSupport.interactInMemory(loop: loop, client: client, server: server)

        var clientChild: Channel?
        let clientSSHHandler = try client.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
        clientSSHHandler.createChannel(channelType: .session) { channel, channelType in
            guard case .session = channelType else {
                return channel.eventLoop.makeFailedFuture(TestError.unexpectedChannelType)
            }
            clientChild = channel
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        try SSHUserAuthTestSupport.interactInMemory(loop: loop, client: client, server: server)

        let serverChild = try #require(serverChildBox.channel, "server never opened the session child channel")
        let deviceID = try #require(authenticatedDeviceIDBox.value, "userauth never authenticated the peer")
        #expect(clientChild?.isActive == true)
        #expect(serverChild.isActive == true)

        // Route the child channel to `pane_control` exactly as a real SSH
        // subsystem-request message would (NIOSSH translates the wire
        // message into this same `userInboundEventTriggered` call on the
        // child channel's pipeline — this is the identical dispatch path,
        // just fired directly instead of driven over the wire, mirroring
        // `SubsystemDispatcherTests`' own approach to exercising
        // `SubsystemDispatcher` in isolation).
        serverChild.pipeline.fireUserInboundEventTriggered(
            SSHChannelRequestEvent.SubsystemRequest(
                subsystem: SSHChannelTypeNames.paneControl,
                wantReply: false
            )
        )
        #expect(serverChild.isActive == true, "pane-control routing must not itself close the channel")

        let registry = SSHConnectionRegistry()
        await registry.register(deviceID: deviceID) {
            try? await server.close().get()
        }

        try store.remove(id: deviceID)
        await registry.revoke(deviceID: deviceID)

        #expect(serverChild.isActive == false, "revocation must close the peer's open pane_control channel")

        let outcome = try SSHUserAuthTestSupport.runUserAuth(key: clientKey, store: store, loop: loop)
        guard case .failure = outcome else {
            Issue.record("expected revoked peer's userauth to fail, got \(outcome)")
            return
        }
    }

    private static func tempDir() -> URL {
        SSHUserAuthTestSupport.tempDir(prefix: "graftty-revocation-cascade")
    }
}

private enum TestError: Error {
    case unexpectedChannelType
}

/// Holds the server-side session channel handed to
/// `inboundChildChannelInitializer`. `EmbeddedChannel`/`NIOSSHHandler`
/// callbacks in this suite all run synchronously on the single test
/// thread pumping `EmbeddedEventLoop.run()`, so no locking is needed —
/// `@unchecked Sendable` only satisfies the `@Sendable` closure
/// signature `inboundChildChannelInitializer` requires.
private final class ChildChannelBox: @unchecked Sendable {
    var channel: Channel?
}

/// Captures the `RemoteDeviceID` `SSHUserAuthDelegate`'s `onAuthenticated`
/// callback fires with — mirrors `WebRTCHostAgent`'s `AuthenticatedPeerBox`.
/// Same single-threaded, synchronous-callback justification as
/// `ChildChannelBox` above applies here.
private final class DeviceIDBox: @unchecked Sendable {
    var value: RemoteDeviceID?
}

/// Offers a single Ed25519 key on the first auth attempt. Mirrors
/// `SSHClientSetup`'s production `SingleKeyUserAuthDelegate` (not
/// reachable here — that type lives in the iOS-only `GrafttyMobileKit`
/// target, gated behind `#if canImport(UIKit)`).
private final class SingleOfferClientAuth: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let key: Curve25519.Signing.PrivateKey
    private var offered = false

    init(key: Curve25519.Signing.PrivateKey) {
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: "graftty",
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key)))
            )
        )
    }
}

/// Trusts any host key. This suite is testing the parent→child close
/// cascade, not host-key pinning (covered elsewhere), so the client
/// side has nothing to gain from validating the server's key.
private final class AcceptAllHostKeys: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}
