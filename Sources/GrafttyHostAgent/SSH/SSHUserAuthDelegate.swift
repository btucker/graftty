import Foundation
import GrafttyKit
import GrafttyProtocol
import NIO
import NIOSSH

/// Trusts a key that redeems a one-time runner invite, returning the new peer,
/// or nil to refuse. Called only for a signed public-key request.
public typealias InviteEnrollment = @Sendable (RunnerEnrollmentToken, RemoteIdentityPublicKey) -> TrustedPeer?

/// @spec REMOTE-8.2
/// @spec REMOTE-8.3
/// @spec REMOTE-6.1
/// @spec REMOTE-7.1
/// Server-side userauth delegate that backs SSH authentication against
/// graftty's `TrustedPeerStore`. Identity is key-only: the peer is resolved
/// entirely by the offered Ed25519 public key. The username matters only for
/// an unknown key, where a runner may carry a one-time invite enrollment in
/// it (REMOTE-33.8); it never selects or changes a trusted peer.
///
/// Ordinary SSH access requires terminal permission. A configured replication
/// receiver may admit a desktop/host peer with only replication permission;
/// SSHHostSessionConfiguration then restricts that peer to replication channels.
public struct SSHUserAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    public let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey

    private let store: TrustedPeerStore
    private let expectedDeviceID: RemoteDeviceID?
    private let allowReplicationOnly: Bool
    private let activePeerRegistry: ActiveRemotePeerRegistry?
    private let closeActiveTransport: (@Sendable () async -> Void)?
    private let onActivePeerRegistered: (@Sendable (ActiveRemotePeerRegistry.EntryID) -> Void)?
    /// REMOTE-9.1: invoked synchronously with the authenticated peer's
    /// `RemoteDeviceID` the moment userauth succeeds — before
    /// `responsePromise` is even resolved, so a caller that stashes the
    /// value in a box sees it populated by the time NIOSSH allows the
    /// first channel-open (which cannot happen until auth completes).
    private let onAuthenticated: (@Sendable (RemoteDeviceID) -> Void)?
    /// Full trusted metadata for transport properties such as display kind.
    /// This is derived from the authenticated public key, not a client frame.
    private let onAuthenticatedPeer: (@Sendable (TrustedPeer) -> Void)?
    private let enroll: InviteEnrollment?

    public init(
        store: TrustedPeerStore,
        expectedDeviceID: RemoteDeviceID? = nil,
        allowReplicationOnly: Bool = false,
        activePeerRegistry: ActiveRemotePeerRegistry? = nil,
        closeActiveTransport: (@Sendable () async -> Void)? = nil,
        onActivePeerRegistered: (@Sendable (ActiveRemotePeerRegistry.EntryID) -> Void)? = nil,
        onAuthenticated: (@Sendable (RemoteDeviceID) -> Void)? = nil,
        onAuthenticatedPeer: (@Sendable (TrustedPeer) -> Void)? = nil,
        enroll: InviteEnrollment? = nil
    ) {
        self.store = store
        self.expectedDeviceID = expectedDeviceID
        self.allowReplicationOnly = allowReplicationOnly
        self.activePeerRegistry = activePeerRegistry
        self.closeActiveTransport = closeActiveTransport
        self.onActivePeerRegistered = onActivePeerRegistered
        self.onAuthenticated = onAuthenticated
        self.onAuthenticatedPeer = onAuthenticatedPeer
        self.enroll = enroll
    }

    /// Compare the permissions captured by userauth after async registration.
    /// Display names and activity timestamps do not change authorization.
    static func hasCurrentAuthorization(_ peer: TrustedPeer, in store: TrustedPeerStore, allowReplicationOnly: Bool = false) -> Bool {
        guard let current = try? store.get(id: peer.id) else { return false }
        return current.id == peer.id && current.kind == peer.kind
            && current.publicKey == peer.publicKey && current.capabilities == peer.capabilities
            && permitsAuthentication(current, allowReplicationOnly: allowReplicationOnly)
    }

    private static func permitsAuthentication(_ peer: TrustedPeer, allowReplicationOnly: Bool) -> Bool {
        peer.capabilities.terminalControl == .allowed
            || (allowReplicationOnly && peer.capabilities.replication == .allowed && (peer.kind == .mac || peer.kind == .linux))
    }

    public func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        // The username never selects a trusted peer — REMOTE-8.3.
        switch request.request {
        case .publicKey(let publicKeyRequest):
            do {
                let publicKey = try Self.publicKey(of: publicKeyRequest.publicKey)
                let fingerprint = RemoteIdentityFingerprint(of: publicKey)
                // NIOSSH calls this only after verifying the signature, which
                // covers the username, so the enrolling key proved possession.
                let known = try store.get(fingerprint: fingerprint)
                let enrolled = known == nil
                    ? RunnerEnrollmentToken(username: request.username).flatMap { enroll?($0, publicKey) } : nil
                if let peer = known ?? enrolled,
                   Self.permitsAuthentication(peer, allowReplicationOnly: allowReplicationOnly),
                   expectedDeviceID == nil || peer.id == expectedDeviceID {
                    if let activePeerRegistry, let closeActiveTransport {
                        let entryID = activePeerRegistry.register(
                            peerID: peer.id,
                            fingerprint: fingerprint,
                            close: closeActiveTransport
                        )
                        onActivePeerRegistered?(entryID)
                    }
                    onAuthenticated?(peer.id)
                    onAuthenticatedPeer?(peer)
                    responsePromise.succeed(.success)
                } else {
                    // Do not distinguish unknown, revoked, or unauthorized peers.
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
        RemoteIdentityFingerprint(of: try publicKey(of: key))
    }

    static func publicKey(of key: NIOSSHPublicKey) throws -> RemoteIdentityPublicKey {
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

        return try RemoteIdentityPublicKey(rawRepresentation: Data(keyBytes))
    }
}

public enum SSHUserAuthError: Error, Equatable {
    case unsupportedKeyFormat
}
