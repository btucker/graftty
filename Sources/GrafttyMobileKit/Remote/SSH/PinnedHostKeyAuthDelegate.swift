#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import NIO
import NIOSSH

/// @spec REMOTE-8.4
/// Client-side `NIOSSHClientServerAuthenticationDelegate` that verifies
/// the server's offered host key against a known fingerprint.
public struct PinnedHostKeyAuthDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let expectedFingerprint: RemoteIdentityFingerprint

    public init(expectedFingerprint: RemoteIdentityFingerprint) {
        self.expectedFingerprint = expectedFingerprint
    }

    public func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        do {
            let offered = try Self.fingerprint(of: hostKey)
            if offered == expectedFingerprint {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(PinnedHostKeyError.hostKeyMismatch(
                    expected: expectedFingerprint,
                    offered: offered
                ))
            }
        } catch {
            validationCompletePromise.fail(error)
        }
    }

    /// Mirror of `SSHUserAuthDelegate.fingerprint(of:)` on the host side.
    /// The two implementations are intentionally identical (post-R6 work
    /// will consolidate); keeping them in lock-step preserves the
    /// canonical key-format check on both ends.
    ///
    /// Derives a `RemoteIdentityFingerprint` from an `NIOSSHPublicKey`
    /// by reading the OpenSSH single-line representation and parsing
    /// the SSH wire format (RFC 4253 §6.6) of its base64 payload:
    ///
    ///     string  "ssh-ed25519"        (u32 length-prefixed type name)
    ///     string  ed25519_public_key   (u32 length-prefixed; 32 bytes)
    ///
    /// `NIOSSHPublicKey` does not expose its raw Ed25519 bytes via a
    /// public accessor — `backingKey` and `writeSSHHostKey` are both
    /// `internal`. The cleanest public path is to round-trip through
    /// `String(openSSHPublicKey:)` (which serialises via the same
    /// internal `writeSSHHostKey`) and base64-decode the result.
    ///
    /// **DRIFT-RISK SYNC POINT.** This implementation is a verbatim
    /// mirror of `SSHUserAuthDelegate.fingerprint(of:)` in
    /// `GrafttyHostAgent`. The two cannot share code (cross-module
    /// import constraint). If you ever broaden the
    /// `typeName == "ssh-ed25519"` check (e.g., to add ECDSA support),
    /// you MUST update BOTH copies — silent client/server divergence
    /// would break host-key pinning and userauth fingerprints. The
    /// inlined test mirror in `SSHAuthLoopbackTests.swift` is a third
    /// sync point.
    static func fingerprint(of key: NIOSSHPublicKey) throws -> RemoteIdentityFingerprint {
        // String form: "<algorithm-id> <base64-of-wire-format>"
        // — exactly two components for our purposes (no comment).
        let openSSH = String(openSSHPublicKey: key)
        let components = openSSH.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard components.count >= 2 else {
            throw PinnedHostKeyError.unsupportedKeyFormat
        }
        guard let rawBytes = Data(base64Encoded: String(components[1])) else {
            throw PinnedHostKeyError.unsupportedKeyFormat
        }

        var buffer = ByteBufferAllocator().buffer(capacity: rawBytes.count)
        buffer.writeContiguousBytes(rawBytes)

        // Parse SSH wire format: <u32 type-len><type><u32 key-len><key>.
        guard
            let typeLen: UInt32 = buffer.readInteger(),
            let typeBytes = buffer.readBytes(length: Int(typeLen)),
            let typeName = String(bytes: typeBytes, encoding: .utf8),
            typeName == "ssh-ed25519",
            let keyLen: UInt32 = buffer.readInteger(),
            keyLen == 32,
            let keyBytes = buffer.readBytes(length: 32)
        else {
            throw PinnedHostKeyError.unsupportedKeyFormat
        }

        let pubkey = try RemoteIdentityPublicKey(rawRepresentation: Data(keyBytes))
        return RemoteIdentityFingerprint(of: pubkey)
    }
}

public enum PinnedHostKeyError: Error, Equatable {
    case hostKeyMismatch(expected: RemoteIdentityFingerprint, offered: RemoteIdentityFingerprint)
    case unsupportedKeyFormat
}
#endif
