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
    public let nonce: RemotePairingNonce
    public let expiry: Date

    public init(
        hostPublicKey: RemoteIdentityPublicKey,
        clientPublicKey: RemoteIdentityPublicKey,
        nonce: RemotePairingNonce,
        expiry: Date
    ) {
        self.hostPublicKey = hostPublicKey
        self.clientPublicKey = clientPublicKey
        self.nonce = nonce
        self.expiry = expiry
    }

    /// Derives a 6-digit verification code via HKDF-SHA256.
    ///
    /// Input keying material: `hostPublicKey || clientPublicKey || expiry (8-byte big-endian Int64)`.
    /// Salt: `nonce.bytes` (makes the code one-time per pairing session).
    /// Info: fixed label `"graftty-remote-pairing-verification-v1"`.
    /// Output: 3 bytes → 6 decimal digits (000000–999999), displayed as `"XXX XXX"`.
    public func verificationCode() -> RemoteVerificationCode {
        let info = Data("graftty-remote-pairing-verification-v1".utf8)
        // Salt must conform to DataProtocol — use raw Data
        let salt = nonce.bytes

        // IKM = hostPublicKey || clientPublicKey || expiry
        var ikm = Data()
        ikm.append(hostPublicKey.rawRepresentation)
        ikm.append(clientPublicKey.rawRepresentation)
        var expiryValue = Int64(expiry.timeIntervalSince1970).bigEndian
        ikm.append(Data(bytes: &expiryValue, count: 8))

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
