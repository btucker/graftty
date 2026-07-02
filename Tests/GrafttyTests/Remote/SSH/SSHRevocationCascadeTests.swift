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
        try store.add(
            TrustedPeer(
                id: RemoteDeviceID.generate(),
                kind: .ipad,
                publicKey: try RemoteIdentityPublicKey(rawRepresentation: clientKey.publicKey.rawRepresentation),
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
        )

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

        try Self.interactInMemory(loop: loop, client: client, server: server)

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
        try Self.interactInMemory(loop: loop, client: client, server: server)

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

    private static func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-revocation-cascade-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Hand-pumps outbound bytes between two `EmbeddedChannel`s sharing
    /// one `EmbeddedEventLoop` until neither side has anything left to
    /// send — the same technique swift-nio-ssh's own
    /// `BackToBackEmbeddedChannel.interactInMemory()` uses to drive a
    /// real SSH handshake between two in-process endpoints without any
    /// real socket or (in our case) any WebRTC data channel.
    private static func interactInMemory(loop: EmbeddedEventLoop, client: EmbeddedChannel, server: EmbeddedChannel) throws {
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
