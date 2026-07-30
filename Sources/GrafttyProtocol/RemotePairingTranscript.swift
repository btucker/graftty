import CryptoKit
import Foundation

// MARK: - RemotePairingNonce

/// Opaque random bytes used once during a pairing ceremony.
public struct RemotePairingNonce: Codable, Sendable, Equatable, Hashable {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    /// Generates a new 16-byte cryptographically random nonce.
    public static func generate() -> RemotePairingNonce {
        let raw = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        return RemotePairingNonce(bytes: Data(raw))
    }
}

// MARK: - RemotePairingTranscript

/// The complete set of inputs to the pairing ceremony.
///
/// `verificationCode()` derives a short code via HKDF-SHA256 so the user can
/// confirm both sides are looking at the same transcript.
public struct RemotePairingTranscript: Codable, Sendable, Equatable {
    public let hostPublicKey: RemoteIdentityPublicKey
    public let clientPublicKey: RemoteIdentityPublicKey
    public let payload: PairingPayload

    public var nonce: RemotePairingNonce { payload.nonce }
    public var expiry: Date { payload.expiry }

    public init(
        hostPublicKey: RemoteIdentityPublicKey,
        clientPublicKey: RemoteIdentityPublicKey,
        payload: PairingPayload
    ) {
        self.hostPublicKey = hostPublicKey
        self.clientPublicKey = clientPublicKey
        // Pairing payloads cross JSON and QR encoders that preserve whole
        // seconds. Normalize here so an in-memory host payload and its decoded
        // client copy always derive the same verification code.
        self.payload = PairingPayload(
            version: payload.version,
            hostDeviceID: payload.hostDeviceID,
            hostKind: payload.hostKind,
            hostDisplayName: payload.hostDisplayName,
            hostPublicKeyFingerprint: payload.hostPublicKeyFingerprint,
            nonce: payload.nonce,
            expiry: Date(
                timeIntervalSince1970: Double(
                    Int64(payload.expiry.timeIntervalSince1970)
                )
            ),
            pairingURL: payload.pairingURL,
            routes: payload.routes
        )
    }

    /// Derives a 6-digit verification code via HKDF-SHA256.
    ///
    /// Input keying material binds both identity keys and every payload field
    /// the client will persist, including the pairing URL and ordered route
    /// list. This makes metadata or route substitution visible as a different
    /// verification code.
    /// Salt: `nonce.bytes` (makes the code one-time per pairing session).
    /// Info: fixed label `"graftty-remote-pairing-verification-v2"`.
    /// Output: 4 bytes → UInt32 mod 1,000,000 → 6 decimal digits (000000–999999), displayed as `"XXX XXX"`.
    public func verificationCode() -> RemoteVerificationCode {
        let info = Data("graftty-remote-pairing-verification-v2".utf8)
        let salt = nonce.bytes

        var ikm = Data()
        ikm.appendFramed(Data("graftty.remote-pairing.transcript.v2".utf8))
        ikm.appendFramed(hostPublicKey.rawRepresentation)
        ikm.appendFramed(clientPublicKey.rawRepresentation)
        ikm.appendFramed(String(payload.version))
        ikm.appendFramed(payload.hostDeviceID.value)
        ikm.appendFramed(payload.hostKind.rawValue)
        ikm.appendFramed(payload.hostDisplayName)
        ikm.appendFramed(payload.hostPublicKeyFingerprint.rawBytes)
        ikm.appendFramed(payload.nonce.bytes)
        ikm.appendFramed(String(Int64(payload.expiry.timeIntervalSince1970)))
        ikm.appendFramed(payload.pairingURL.absoluteString)
        ikm.appendFramed(String(payload.routes.count))
        for route in payload.routes {
            ikm.appendFramed(route.kind.rawValue)
            ikm.appendFramed(route.baseURL.absoluteString)
        }

        let ikmKey = SymmetricKey(data: ikm)

        // Derive 4 bytes; treat as UInt32 and mod 1_000_000 for 6 digits
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikmKey, salt: salt, info: info, outputByteCount: 4)
        let derivedBytes = derived.withUnsafeBytes { Array($0) }

        let raw = UInt32(derivedBytes[0]) << 24
                | UInt32(derivedBytes[1]) << 16
                | UInt32(derivedBytes[2]) << 8
                | UInt32(derivedBytes[3])
        let sixDigits = Int(raw) % 1_000_000
        let digits = String(format: "%06d", sixDigits)

        return RemoteVerificationCode(digits: digits)
    }
}

private extension Data {
    mutating func appendFramed(_ value: String) {
        appendFramed(Data(value.utf8))
    }

    mutating func appendFramed(_ value: Data) {
        var length = UInt64(value.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(value)
    }
}

// MARK: - RemoteVerificationCode

/// A short human-displayable code confirming both sides share the same pairing transcript.
public struct RemoteVerificationCode: Codable, Sendable, Equatable, Hashable {
    /// Six decimal digits with no separator, e.g. `"123456"`.
    public let digits: String

    /// Six digits split into two groups of three with a space, e.g. `"123 456"`.
    public var display: String {
        guard digits.count == 6 else { return digits }
        let mid = digits.index(digits.startIndex, offsetBy: 3)
        return String(digits[..<mid]) + " " + String(digits[mid...])
    }

    public init(digits: String) {
        self.digits = digits
    }
}
