import Foundation
import GrafttyKit
import GrafttyProtocol
import NIO
import NIOSSH

/// @spec REMOTE-8.2
/// @spec REMOTE-8.3
/// @spec REMOTE-6.1
/// @spec REMOTE-7.1
/// Server-side userauth delegate that backs SSH authentication against
/// graftty's `TrustedPeerStore`. Identity is key-only — the SSH
/// userauth `username` field is deliberately ignored; the peer is
/// resolved entirely by the offered Ed25519 public key.
///
/// REMOTE-6.1 / REMOTE-7.1 capability enforcement happens here, not at
/// channel-open: all R5-scope channel types (session/pty, panes-state,
/// pane-control) require the same `terminalControl == .allowed`
/// capability, so a peer without it cannot authenticate at all.
/// SSH_MSG_USERAUTH_FAILURE closes every R5 channel-open gate by
/// exclusion. When per-channel capability differentiation actually
/// matters (port-tunnel REMOTE-4.x with `askEachTime`), that PR will
/// introduce a per-connection `AuthenticatedPeerBox` and migrate the
/// check to channel-open time.
public struct SSHUserAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    public let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey

    private let store: TrustedPeerStore
    /// REMOTE-9.1: invoked synchronously with the authenticated peer's
    /// `RemoteDeviceID` the moment userauth succeeds — before
    /// `responsePromise` is even resolved, so a caller that stashes the
    /// value in a box sees it populated by the time NIOSSH allows the
    /// first channel-open (which cannot happen until auth completes).
    private let onAuthenticated: (@Sendable (RemoteDeviceID) -> Void)?

    public init(store: TrustedPeerStore, onAuthenticated: (@Sendable (RemoteDeviceID) -> Void)? = nil) {
        self.store = store
        self.onAuthenticated = onAuthenticated
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
                if let peer = try store.get(fingerprint: fingerprint),
                   peer.capabilities.terminalControl == .allowed {
                    onAuthenticated?(peer.id)
                    responsePromise.succeed(.success)
                } else {
                    // Either no matching trusted peer (unpaired / revoked) or the
                    // peer's terminalControl capability has been disabled. Reject
                    // with the same SSH_MSG_USERAUTH_FAILURE — clients can't tell
                    // the difference, which prevents probing for revoked-vs-unpaired
                    // status. REMOTE-6.1 / REMOTE-7.1 are satisfied by exclusion:
                    // a peer that can't authenticate can't open any channel.
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
    ///
    /// **DRIFT-RISK SYNC POINT.** This implementation is a verbatim
    /// mirror of `PinnedHostKeyAuthDelegate.fingerprint(of:)` in
    /// `GrafttyMobileKit`. The two cannot share code because
    /// `GrafttyMobileKit` can't import `GrafttyHostAgent`
    /// (`GrafttyKit` imports AppKit). If you ever broaden the
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
