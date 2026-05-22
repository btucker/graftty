import CryptoKit
import Foundation
import GrafttyKit
import NIO
import NIOSSH

/// @spec REMOTE-8.5
/// Factory for the server-side `NIOSSHHandler`. Encapsulates:
///   - the host key loaded from `HostIdentityStore`
///   - the userauth delegate that validates against `TrustedPeerStore`
///   - the transport-protection allowlist (swift-nio-ssh defaults: AES-256-GCM
///     and AES-128-GCM — see note below)
///   - the inbound child-channel initializer for incoming SSH channels
///     (terminal session, panes-state, pane-control — wired in R4/R5)
///
/// **REMOTE-8.5 cipher allowlist note:** The original spec calls for
/// AES-256-GCM only. `AES256GCMOpenSSHTransportProtection` is declared
/// `internal` in swift-nio-ssh 0.13 and cannot be referenced from outside
/// the module. Until upstream exposes the type publicly, this factory
/// accepts swift-nio-ssh's bundled defaults, which today are
/// [AES-256-GCM, AES-128-GCM]. REMOTE-8.5 should be revised to relax
/// the requirement to "AES-256-GCM and AES-128-GCM" once the factory is
/// wired end-to-end, or revisited if swift-nio-ssh adds a public API for
/// selecting individual cipher suites.
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
