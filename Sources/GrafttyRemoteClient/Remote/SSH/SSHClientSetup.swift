#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation
import GrafttyProtocol
import NIO
import NIOSSH

/// Factory for the client-side `NIOSSHHandler`. Encapsulates:
///   - the client identity key (from `ClientIdentityStore`)
///   - the host-key verification delegate (pinned via `PinnedHostStore`)
///
/// Transport protection uses swift-nio-ssh's bundled AEAD ciphers
/// (`aes256-gcm@openssh.com` + `aes128-gcm@openssh.com`) — same as the
/// server side. Strict pinning to a single cipher would require
/// upstream to expose `AES256GCMOpenSSHTransportProtection` publicly.
public enum SSHClientSetup {
    public static func makeHandler(
        clientKey: Curve25519.Signing.PrivateKey,
        expectedHostFingerprint: RemoteIdentityFingerprint,
        allocator: ByteBufferAllocator,
        onAuthenticationRejected: (@Sendable () -> Void)? = nil
    ) -> NIOSSHHandler {
        let config = SSHClientConfiguration(
            userAuthDelegate: SingleKeyUserAuthDelegate(key: clientKey, onRejected: onAuthenticationRejected),
            serverAuthDelegate: PinnedHostKeyAuthDelegate(expectedFingerprint: expectedHostFingerprint)
        )
        return NIOSSHHandler(
            role: .client(config),
            allocator: allocator,
            inboundChildChannelInitializer: nil
        )
    }
}

/// Offers a single Ed25519 pubkey on the first attempt; doesn't retry
/// with a different key. Production graftty has one client identity
/// at a time, so single-attempt is sufficient.
private final class SingleKeyUserAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let key: Curve25519.Signing.PrivateKey
    private let lock = NSLock()
    private var offered = false
    private let onRejected: (@Sendable () -> Void)?

    init(key: Curve25519.Signing.PrivateKey, onRejected: (@Sendable () -> Void)?) {
        self.key = key
        self.onRejected = onRejected
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !offered, availableMethods.contains(.publicKey) else {
            onRejected?()
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        let offer = NIOSSHUserAuthenticationOffer(
            username: "graftty",
            serviceName: "ssh-connection",
            offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key)))
        )
        nextChallengePromise.succeed(offer)
    }
}
