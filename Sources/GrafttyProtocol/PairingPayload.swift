import Foundation

// MARK: - PairingPayload

/// The content of the QR code displayed during a local pairing ceremony.
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

    // MARK: - QR encoding / decoding

    /// Prefix prepended to every QR string for parser robustness.
    private static let qrPrefix = "GRAFTTY2:"

    /// Supported payload version.
    private static let supportedVersion = RemoteAccessProtocol.version

    /// Encodes the payload to a compact QR-safe string.
    ///
    /// Format: `"GRAFTTY2:<base64url-no-padding(JSON)>"`.
    /// The JSON is compact (`.sortedKeys`, no pretty printing) to keep QR
    /// modules small.
    public func qrEncoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(self)
        // Base64URL, no padding
        let b64 = jsonData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(Self.qrPrefix)\(b64)"
    }

    /// Decodes a QR string produced by `qrEncoded()`.
    ///
    /// Throws `DecodeError` for malformed input or unsupported versions.
    public static func decodeQR(_ string: String) throws -> PairingPayload {
        guard string.hasPrefix(qrPrefix) else {
            throw DecodeError.missingPrefix
        }
        let b64url = String(string.dropFirst(qrPrefix.count))
        // Convert base64URL → standard base64 with padding
        var b64 = b64url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingNeeded = (4 - b64.count % 4) % 4
        b64 += String(repeating: "=", count: paddingNeeded)

        guard let jsonData = Data(base64Encoded: b64) else {
            throw DecodeError.malformedBase64
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: PairingPayload
        do {
            payload = try decoder.decode(PairingPayload.self, from: jsonData)
        } catch {
            throw DecodeError.malformedJSON
        }

        guard payload.version == supportedVersion else {
            throw DecodeError.unsupportedVersion(payload.version)
        }

        // Accept http or https. Plaintext HTTP is safe because the pairing
        // exchange is authenticated by the QR-pinned fingerprint, single-use
        // nonce, and verification code. Any other scheme (file:, javascript:,
        // ftp:, nil, etc.) is rejected.
        let scheme = payload.pairingURL.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw DecodeError.insecureURL
        }

        for route in payload.routes {
            let routeScheme = route.baseURL.scheme?.lowercased()
            guard routeScheme == "http" || routeScheme == "https" else {
                throw DecodeError.insecureURL
            }
        }

        return payload
    }

    // MARK: - DecodeError

    public enum DecodeError: Swift.Error, Equatable {
        case missingPrefix
        case malformedBase64
        case malformedJSON
        case unsupportedVersion(Int)
        /// The `pairingURL` in the QR payload uses a scheme other than http or https.
        /// Only `http://` and `https://` endpoints are accepted; other schemes (file:,
        /// javascript:, ftp:, nil, etc.) are rejected.
        case insecureURL
    }
}
