import CryptoKit
import Foundation
import GrafttyKit
import NIO
import NIOSSH

/// @spec REMOTE-8.5
/// Factory for the server-side `NIOSSHHandler`. Encapsulates:
///   - the host key loaded from `HostIdentityStore`
///   - the userauth delegate that validates against `TrustedPeerStore`
///   - the inbound child-channel initializer for incoming SSH channels
///     (terminal session, panes-state, pane-control — wired in R4/R5)
///
/// Transport protection uses swift-nio-ssh's bundled AEAD ciphers
/// (`aes256-gcm@openssh.com` + `aes128-gcm@openssh.com`); no weak or
/// legacy ciphers are reachable because the library ships none.
/// Strict pinning to a single cipher would require upstream to expose
/// `AES256GCMOpenSSHTransportProtection` publicly — today it's `internal`.
public enum SSHServerSetup {
    public static func makeHandler(
        hostKey: Curve25519.Signing.PrivateKey,
        trustedPeerStore: TrustedPeerStore,
        allocator: ByteBufferAllocator,
        inboundChildChannelInitializer: @escaping @Sendable (Channel, SSHChannelType) -> EventLoopFuture<Void>
    ) -> NIOSSHHandler {
        let config = SSHServerConfiguration(
            hostKeys: [NIOSSHPrivateKey(ed25519Key: hostKey)],
            userAuthDelegate: SSHUserAuthDelegate(store: trustedPeerStore)
        )
        // REMOTE-8.5: transportProtectionSchemes is intentionally left at
        // swift-nio-ssh's bundled defaults (AES-256-GCM + AES-128-GCM)
        // because `AES256GCMOpenSSHTransportProtection` is internal in
        // swift-nio-ssh 0.13 and cannot be referenced here directly.
        return NIOSSHHandler(
            role: .server(config),
            allocator: allocator,
            inboundChildChannelInitializer: inboundChildChannelInitializer
        )
    }
}
