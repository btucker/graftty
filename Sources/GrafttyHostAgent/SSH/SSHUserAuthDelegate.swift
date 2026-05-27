import Foundation
import GrafttyKit
import GrafttyProtocol
import NIO
import NIOSSH

/// @spec REMOTE-8.2
/// @spec REMOTE-8.3
/// Server-side userauth delegate that backs SSH authentication against
/// graftty's `TrustedPeerStore`. Identity is key-only — the SSH
/// userauth `username` field is deliberately ignored; the peer is
/// resolved entirely by the offered Ed25519 public key.
public struct SSHUserAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    public let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey

    private let store: TrustedPeerStore

    public init(store: TrustedPeerStore) {
        self.store = store
    }

    public func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        // request.username is deliberately ignored — REMOTE-8.3.
        switch request.request {
        case .publicKey(let publicKeyRequest):
            do {
                let fingerprint = try Self.fingerprint(of: publicKeyRequest.publicKey)
                if try store.get(fingerprint: fingerprint) != nil {
                    responsePromise.succeed(.success)
                } else {
                    // No matching trusted peer — reject. The peer is
                    // either unpaired or has been revoked since pairing.
                    responsePromise.succeed(.failure)
                }
            } catch {
                // A thrown error here (unsupported key format from fingerprint(of:),
                // or I/O failure from store.get) cannot be recovered into a real
                // identity. Treat it as auth failure rather than a channel error —
                // succeed(.failure) sends a clean SSH_MSG_USERAUTH_FAILURE; fail(error)
                // would tear the channel down with no SSH-layer error message.
                responsePromise.succeed(.failure)
            }
        // REMOTE-8.2: reject every non-publickey method immediately.
        case .password, .hostBased, .none:
            responsePromise.succeed(.failure)
        @unknown default:
            responsePromise.succeed(.failure)
        }
    }

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
    static func fingerprint(of key: NIOSSHPublicKey) throws -> RemoteIdentityFingerprint {
        // String form: "<algorithm-id> <base64-of-wire-format>"
        // — exactly two components for our purposes (no comment).
        let openSSH = String(openSSHPublicKey: key)
        let components = openSSH.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard components.count >= 2 else {
            throw SSHUserAuthError.unsupportedKeyFormat
        }
        guard let rawBytes = Data(base64Encoded: String(components[1])) else {
            throw SSHUserAuthError.unsupportedKeyFormat
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
            throw SSHUserAuthError.unsupportedKeyFormat
        }

        let pubkey = try RemoteIdentityPublicKey(rawRepresentation: Data(keyBytes))
        return RemoteIdentityFingerprint(of: pubkey)
    }
}

public enum SSHUserAuthError: Error, Equatable {
    case unsupportedKeyFormat
}
