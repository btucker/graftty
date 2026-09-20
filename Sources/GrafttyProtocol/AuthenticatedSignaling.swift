import CryptoKit
import Foundation

/// Shared constants for the breaking, key-authenticated remote-access protocol.
public enum RemoteAccessProtocol {
    public static let version = 2
    public static let pairedAccessPort = 8_800
    public static let challengePath = "v2/rtc/challenge"
    public static let offerPath = "v2/rtc/offer"
}

/// A host-advertised way to reach the same paired-access listener.
public struct RemoteConnectionRoute: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable, Equatable, Hashable {
        case lan
        case tailscaleDNS
        case tailscaleIP
    }

    public let kind: Kind
    public let baseURL: URL

    public init(kind: Kind, baseURL: URL) {
        self.kind = kind
        self.baseURL = baseURL
    }
}

/// Authenticated reachability probe sent before allocating WebRTC resources.
public struct SignalingChallengeRequest: Codable, Sendable, Equatable {
    public let version: Int
    public let clientDeviceID: RemoteDeviceID
    public let clientNonce: Data
    public let signature: Data

    public init(
        clientDeviceID: RemoteDeviceID,
        clientNonce: Data,
        signingKey: Curve25519.Signing.PrivateKey
    ) throws {
        self.version = RemoteAccessProtocol.version
        self.clientDeviceID = clientDeviceID
        self.clientNonce = clientNonce
        self.signature = try signingKey.signature(
            for: Self.signingTranscript(
                version: version,
                clientDeviceID: clientDeviceID,
                clientNonce: clientNonce
            )
        )
    }

    public func isValid(using publicKey: RemoteIdentityPublicKey) -> Bool {
        guard version == RemoteAccessProtocol.version,
            clientNonce.count == 32,
            let key = try? Curve25519.Signing.PublicKey(
                rawRepresentation: publicKey.rawRepresentation
            )
        else {
            return false
        }
        return key.isValidSignature(
            signature,
            for: Self.signingTranscript(
                version: version,
                clientDeviceID: clientDeviceID,
                clientNonce: clientNonce
            )
        )
    }

    private static func signingTranscript(
        version: Int,
        clientDeviceID: RemoteDeviceID,
        clientNonce: Data
    ) -> Data {
        SignalingTranscript(domain: "graftty.signaling.v2.challenge-request")
            .appending(version)
            .appending(clientDeviceID.value)
            .appending(clientNonce)
            .data
    }
}

/// Host-authenticated response proving both identity and current routes.
public struct SignalingChallengeResponse: Codable, Sendable, Equatable {
    public let version: Int
    public let hostDeviceID: RemoteDeviceID
    public let clientDeviceID: RemoteDeviceID
    public let clientNonce: Data
    public let hostNonce: Data
    public let expiresAt: Date
    public let routes: [RemoteConnectionRoute]
    public let signature: Data

    public init(
        hostDeviceID: RemoteDeviceID,
        clientDeviceID: RemoteDeviceID,
        clientNonce: Data,
        hostNonce: Data,
        expiresAt: Date,
        routes: [RemoteConnectionRoute],
        signingKey: Curve25519.Signing.PrivateKey
    ) throws {
        self.version = RemoteAccessProtocol.version
        self.hostDeviceID = hostDeviceID
        self.clientDeviceID = clientDeviceID
        self.clientNonce = clientNonce
        self.hostNonce = hostNonce
        self.expiresAt = expiresAt
        self.routes = routes
        self.signature = try signingKey.signature(
            for: Self.transcript(
                version: version,
                hostDeviceID: hostDeviceID,
                clientDeviceID: clientDeviceID,
                clientNonce: clientNonce,
                hostNonce: hostNonce,
                expiresAt: expiresAt,
                routes: routes
            ))
    }

    public func isValid(
        expectedHostID: RemoteDeviceID,
        expectedClientID: RemoteDeviceID,
        expectedClientNonce: Data,
        now: Date,
        using publicKey: RemoteIdentityPublicKey
    ) -> Bool {
        guard version == RemoteAccessProtocol.version,
            hostDeviceID == expectedHostID,
            clientDeviceID == expectedClientID,
            clientNonce == expectedClientNonce,
            hostNonce.count == 32,
            now <= expiresAt,
            let key = try? Curve25519.Signing.PublicKey(
                rawRepresentation: publicKey.rawRepresentation
            )
        else {
            return false
        }
        return key.isValidSignature(signature, for: signingTranscript)
    }

    fileprivate var signingTranscript: Data {
        Self.transcript(
            version: version,
            hostDeviceID: hostDeviceID,
            clientDeviceID: clientDeviceID,
            clientNonce: clientNonce,
            hostNonce: hostNonce,
            expiresAt: expiresAt,
            routes: routes
        )
    }

    private static func transcript(
        version: Int,
        hostDeviceID: RemoteDeviceID,
        clientDeviceID: RemoteDeviceID,
        clientNonce: Data,
        hostNonce: Data,
        expiresAt: Date,
        routes: [RemoteConnectionRoute]
    ) -> Data {
        SignalingTranscript(domain: "graftty.signaling.v2.challenge-response")
            .appending(version)
            .appending(hostDeviceID.value)
            .appending(clientDeviceID.value)
            .appending(clientNonce)
            .appending(hostNonce)
            .appending(expiresAt)
            .appending(routes)
            .data
    }
}

/// SDP offer authenticated by the paired client's identity key.
public struct AuthenticatedSignalingOffer: Codable, Sendable, Equatable {
    public let version: Int
    public let hostDeviceID: RemoteDeviceID
    public let clientDeviceID: RemoteDeviceID
    public let clientNonce: Data
    public let hostNonce: Data
    public let expiresAt: Date
    public let sdp: String
    /// Present only when the user explicitly asked to replace this device's
    /// prior host connection. `nil` preserves the original protocol-v2 wire
    /// shape and signing transcript for ordinary connects.
    public let replacesExistingConnection: Bool?
    /// Optional proof over the replacement extension. The base `signature`
    /// remains bound to the released protocol-v2 transcript so older hosts can
    /// still authenticate a newer client's offer when their slot is idle.
    public let replacementSignature: Data?
    public let signature: Data

    /// Replacement intent is also carried inside the legacy-signed SDP. A
    /// route can remove optional JSON fields, but it cannot remove this SDP
    /// attribute without invalidating the base signature that protocol-v2
    /// hosts already verify.
    public var hasSignedReplacementIntentMarker: Bool {
        sdp.split(whereSeparator: { $0.isNewline }).contains {
            $0 == Substring(Self.replacementIntentSDPAttribute)
        }
    }

    public init(
        challenge: SignalingChallengeResponse,
        sdp: String,
        replacesExistingConnection: Bool = false,
        signingKey: Curve25519.Signing.PrivateKey
    ) throws {
        self.version = RemoteAccessProtocol.version
        self.hostDeviceID = challenge.hostDeviceID
        self.clientDeviceID = challenge.clientDeviceID
        self.clientNonce = challenge.clientNonce
        self.hostNonce = challenge.hostNonce
        self.expiresAt = challenge.expiresAt
        self.sdp = replacesExistingConnection
            ? Self.appendingReplacementIntentMarker(to: sdp)
            : sdp
        self.replacesExistingConnection = replacesExistingConnection ? true : nil
        let baseTranscript = Self.transcript(
            version: version,
            hostDeviceID: hostDeviceID,
            clientDeviceID: clientDeviceID,
            clientNonce: clientNonce,
            hostNonce: hostNonce,
            expiresAt: expiresAt,
            sdp: self.sdp
        )
        self.signature = try signingKey.signature(for: baseTranscript)
        self.replacementSignature = replacesExistingConnection
            ? try signingKey.signature(
                for: Self.replacementTranscript(baseTranscript: baseTranscript)
            )
            : nil
    }

    public func isValid(using publicKey: RemoteIdentityPublicKey) -> Bool {
        guard version == RemoteAccessProtocol.version,
            clientNonce.count == 32,
            hostNonce.count == 32,
            let key = try? Curve25519.Signing.PublicKey(
                rawRepresentation: publicKey.rawRepresentation
            )
        else {
            return false
        }
        return key.isValidSignature(signature, for: signingTranscript)
    }

    public func hasValidReplacementIntent(
        using publicKey: RemoteIdentityPublicKey
    ) -> Bool {
        guard replacesExistingConnection == true,
              let replacementSignature,
              let key = try? Curve25519.Signing.PublicKey(
                rawRepresentation: publicKey.rawRepresentation
              )
        else {
            return false
        }
        return key.isValidSignature(
            replacementSignature,
            for: Self.replacementTranscript(baseTranscript: signingTranscript)
        )
    }

    fileprivate var signingTranscript: Data {
        Self.transcript(
            version: version,
            hostDeviceID: hostDeviceID,
            clientDeviceID: clientDeviceID,
            clientNonce: clientNonce,
            hostNonce: hostNonce,
            expiresAt: expiresAt,
            sdp: sdp
        )
    }

    private static func transcript(
        version: Int,
        hostDeviceID: RemoteDeviceID,
        clientDeviceID: RemoteDeviceID,
        clientNonce: Data,
        hostNonce: Data,
        expiresAt: Date,
        sdp: String
    ) -> Data {
        SignalingTranscript(domain: "graftty.signaling.v2.offer")
            .appending(version)
            .appending(hostDeviceID.value)
            .appending(clientDeviceID.value)
            .appending(clientNonce)
            .appending(hostNonce)
            .appending(expiresAt)
            .appending(sdp)
            .data
    }

    private static func replacementTranscript(baseTranscript: Data) -> Data {
        SignalingTranscript(domain: "graftty.signaling.v2.offer.replacement")
            .appending(baseTranscript)
            .appending("replace-existing-connection")
            .data
    }

    private static let replacementIntentSDPAttribute =
        "a=x-graftty-replacement-intent:1"

    private static func appendingReplacementIntentMarker(to sdp: String) -> String {
        let separator = sdp.last?.isNewline == true ? "" : "\r\n"
        return sdp + separator + replacementIntentSDPAttribute + "\r\n"
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case hostDeviceID
        case clientDeviceID
        case clientNonce
        case hostNonce
        case expiresAt
        case sdp
        case replacesExistingConnection
        case replacementSignature
        case signature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        hostDeviceID = try container.decode(RemoteDeviceID.self, forKey: .hostDeviceID)
        clientDeviceID = try container.decode(RemoteDeviceID.self, forKey: .clientDeviceID)
        clientNonce = try container.decode(Data.self, forKey: .clientNonce)
        hostNonce = try container.decode(Data.self, forKey: .hostNonce)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        sdp = try container.decode(String.self, forKey: .sdp)
        replacesExistingConnection = try container.decodeIfPresent(
            Bool.self,
            forKey: .replacesExistingConnection
        ) == true ? true : nil
        replacementSignature = try container.decodeIfPresent(
            Data.self,
            forKey: .replacementSignature
        )
        signature = try container.decode(Data.self, forKey: .signature)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(hostDeviceID, forKey: .hostDeviceID)
        try container.encode(clientDeviceID, forKey: .clientDeviceID)
        try container.encode(clientNonce, forKey: .clientNonce)
        try container.encode(hostNonce, forKey: .hostNonce)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(sdp, forKey: .sdp)
        try container.encodeIfPresent(
            replacesExistingConnection,
            forKey: .replacesExistingConnection
        )
        try container.encodeIfPresent(
            replacementSignature,
            forKey: .replacementSignature
        )
        try container.encode(signature, forKey: .signature)
    }
}

/// SDP answer and refreshed route list authenticated by the host key.
/// @spec REMOTE-2.13: When an authenticated client connects, the host shall supply separately signed wake addresses as an optional protocol-v2 extension that older clients can ignore.
public struct AuthenticatedSignalingAnswer: Codable, Sendable, Equatable {
    public let version: Int
    public let hostDeviceID: RemoteDeviceID
    public let clientDeviceID: RemoteDeviceID
    public let hostNonce: Data
    public let sdp: String
    public let routes: [RemoteConnectionRoute]
    public let signature: Data
    public let wakeOnLAN: WakeOnLANAdvertisement?

    public init(
        offer: AuthenticatedSignalingOffer,
        sdp: String,
        routes: [RemoteConnectionRoute],
        signingKey: Curve25519.Signing.PrivateKey,
        wakeOnLAN: WakeOnLANAdvertisement? = nil
    ) throws {
        self.version = RemoteAccessProtocol.version
        self.hostDeviceID = offer.hostDeviceID
        self.clientDeviceID = offer.clientDeviceID
        self.hostNonce = offer.hostNonce
        self.sdp = sdp
        self.routes = routes
        self.wakeOnLAN = wakeOnLAN
        self.signature = try signingKey.signature(
            for: Self.transcript(
                version: version,
                hostDeviceID: hostDeviceID,
                clientDeviceID: clientDeviceID,
                hostNonce: hostNonce,
                sdp: sdp,
                routes: routes
            ))
    }

    public func isValid(
        for offer: AuthenticatedSignalingOffer,
        using publicKey: RemoteIdentityPublicKey
    ) -> Bool {
        guard version == RemoteAccessProtocol.version,
            hostDeviceID == offer.hostDeviceID,
            clientDeviceID == offer.clientDeviceID,
            hostNonce == offer.hostNonce,
            let key = try? Curve25519.Signing.PublicKey(
                rawRepresentation: publicKey.rawRepresentation
            )
        else {
            return false
        }
        return key.isValidSignature(signature, for: signingTranscript)
    }

    fileprivate var signingTranscript: Data {
        Self.transcript(
            version: version,
            hostDeviceID: hostDeviceID,
            clientDeviceID: clientDeviceID,
            hostNonce: hostNonce,
            sdp: sdp,
            routes: routes
        )
    }

    private static func transcript(
        version: Int,
        hostDeviceID: RemoteDeviceID,
        clientDeviceID: RemoteDeviceID,
        hostNonce: Data,
        sdp: String,
        routes: [RemoteConnectionRoute]
    ) -> Data {
        SignalingTranscript(domain: "graftty.signaling.v2.answer")
            .appending(version)
            .appending(hostDeviceID.value)
            .appending(clientDeviceID.value)
            .appending(hostNonce)
            .appending(sdp)
            .appending(routes)
            .data
    }
}

private struct SignalingTranscript {
    private(set) var data: Data

    init(domain: String) {
        self.data = Data()
        self = appending(domain)
    }

    func appending(_ value: Int) -> Self {
        appending(String(value))
    }

    func appending(_ value: Date) -> Self {
        appending(String(Int64((value.timeIntervalSince1970 * 1_000).rounded())))
    }

    func appending(_ value: String) -> Self {
        appending(Data(value.utf8))
    }

    func appending(_ value: Data) -> Self {
        var copy = self
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { copy.data.append(contentsOf: $0) }
        copy.data.append(value)
        return copy
    }

    func appending(_ routes: [RemoteConnectionRoute]) -> Self {
        let canonicalRoutes = routes.sorted {
            if $0.kind.rawValue == $1.kind.rawValue {
                return $0.baseURL.absoluteString < $1.baseURL.absoluteString
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        var copy = appending(canonicalRoutes.count)
        for route in canonicalRoutes {
            copy =
                copy
                .appending(route.kind.rawValue)
                .appending(route.baseURL.absoluteString)
        }
        return copy
    }
}
