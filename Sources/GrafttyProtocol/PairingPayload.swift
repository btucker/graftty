import Foundation

// MARK: - PairingPayload

/// The bootstrap response for a local pairing ceremony.
///
/// Carries everything the client needs to initiate contact with the host:
/// where to POST, which host identity to expect, and a one-time nonce that
/// prevents replay attacks.
public struct PairingPayload: Codable, Sendable, Equatable, Hashable {

    // MARK: Properties

    /// Protocol version. Version 2 is a breaking trust-store boundary.
    public let version: Int

    /// The host's stable device identifier.
    public let hostDeviceID: RemoteDeviceID

    /// The host device category (mac, iphone, ipad).
    public let hostKind: RemoteDeviceKind

    /// Human-readable name shown to the user on the client side.
    public let hostDisplayName: String

    /// SHA-256 fingerprint of the host's public key.
    ///
    /// The full public key travels in the HTTPS exchange; the fingerprint
    /// lets the client pin to the expected host identity before TLS even
    /// completes, acting as an anti-MITM check during the ceremony.
    public let hostPublicKeyFingerprint: RemoteIdentityFingerprint

    /// One-time nonce for this pairing session.
    public let nonce: RemotePairingNonce

    /// Wall-clock expiry for this session. After this date the nonce must be
    /// rejected.
    public let expiry: Date

    /// The local HTTPS endpoint the client should POST to (e.g.
    /// `"http://hostname.local:8800/v2/pairing"`).
    public let pairingURL: URL

    /// Initial ways to reach the paired-access listener. The host returns a
    /// freshly signed route list during every authenticated connection.
    public let routes: [RemoteConnectionRoute]

    // MARK: Init

    public init(
        version: Int = RemoteAccessProtocol.version,
        hostDeviceID: RemoteDeviceID,
        hostKind: RemoteDeviceKind,
        hostDisplayName: String,
        hostPublicKeyFingerprint: RemoteIdentityFingerprint,
        nonce: RemotePairingNonce,
        expiry: Date,
        pairingURL: URL,
        routes: [RemoteConnectionRoute] = []
    ) {
        self.version = version
        self.hostDeviceID = hostDeviceID
        self.hostKind = hostKind
        self.hostDisplayName = hostDisplayName
        self.hostPublicKeyFingerprint = hostPublicKeyFingerprint
        self.nonce = nonce
        self.expiry = expiry
        self.pairingURL = pairingURL
        self.routes = routes
    }

}
