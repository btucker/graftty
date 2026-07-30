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
    public let signature: Data

    public init(
        challenge: SignalingChallengeResponse,
        sdp: String,
        signingKey: Curve25519.Signing.PrivateKey
    ) throws {
        self.version = RemoteAccessProtocol.version
        self.hostDeviceID = challenge.hostDeviceID
        self.clientDeviceID = challenge.clientDeviceID
        self.clientNonce = challenge.clientNonce
        self.hostNonce = challenge.hostNonce
        self.expiresAt = challenge.expiresAt
        self.sdp = sdp
        self.signature = try signingKey.signature(
            for: Self.transcript(
                version: version,
                hostDeviceID: hostDeviceID,
                clientDeviceID: clientDeviceID,
                clientNonce: clientNonce,
                hostNonce: hostNonce,
                expiresAt: expiresAt,
                sdp: sdp
            ))
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
}

/// SDP answer and refreshed route list authenticated by the host key.
public struct AuthenticatedSignalingAnswer: Codable, Sendable, Equatable {
    public let version: Int
    public let hostDeviceID: RemoteDeviceID
    public let clientDeviceID: RemoteDeviceID
    public let hostNonce: Data
    public let sdp: String
    public let routes: [RemoteConnectionRoute]
    public let signature: Data

    public init(
        offer: AuthenticatedSignalingOffer,
        sdp: String,
        routes: [RemoteConnectionRoute],
        signingKey: Curve25519.Signing.PrivateKey
    ) throws {
        self.version = RemoteAccessProtocol.version
        self.hostDeviceID = offer.hostDeviceID
        self.clientDeviceID = offer.clientDeviceID
        self.hostNonce = offer.hostNonce
        self.sdp = sdp
        self.routes = routes
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
