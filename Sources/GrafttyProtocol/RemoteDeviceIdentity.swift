import CryptoKit
import Foundation

// MARK: - RemoteDeviceID

/// An opaque identifier for a remote device. UUID-derived for uniqueness.
public struct RemoteDeviceID: Codable, Sendable, Equatable, Hashable {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    /// Generates a new unique device ID from a UUID.
    public static func generate() -> RemoteDeviceID {
        RemoteDeviceID(value: UUID().uuidString)
    }
}

// MARK: - RemoteDeviceKind

/// The category of a remote device. String raw values allow future cases
/// without breaking existing JSON payloads.
public enum RemoteDeviceKind: String, Codable, Sendable, Equatable, Hashable {
    case mac
    case iphone
    case ipad
}

// MARK: - RemoteIdentityPublicKey

/// Wraps the raw 32-byte representation of an X25519 static identity key.
public struct RemoteIdentityPublicKey: Codable, Sendable, Equatable, Hashable {
    public let rawRepresentation: Data

    /// Errors produced by `init(rawRepresentation:)`.
    public enum Error: Swift.Error {
        case invalidLength(expected: Int, actual: Int)
    }

    /// Initialises from exactly 32 bytes. Throws if `rawRepresentation` is not 32 bytes.
    public init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == 32 else {
            throw Error.invalidLength(expected: 32, actual: rawRepresentation.count)
        }
        self.rawRepresentation = rawRepresentation
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case rawRepresentation }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let data = try container.decode(Data.self, forKey: .rawRepresentation)
        do {
            try self.init(rawRepresentation: data)
        } catch Error.invalidLength(let expected, let actual) {
            throw DecodingError.dataCorruptedError(
                forKey: .rawRepresentation,
                in: container,
                debugDescription: "Expected \(expected) bytes, got \(actual)."
            )
        }
    }
}

// MARK: - RemoteIdentityFingerprint

/// A stable, displayable fingerprint derived from a `RemoteIdentityPublicKey`.
///
/// Implementation: SHA-256 over the canonical 32-byte public key representation.
/// Display format: uppercase hex in eight 4-byte (8-character) blocks separated by spaces,
/// e.g. `"AABBCCDD EEFF0011 …"`.
public struct RemoteIdentityFingerprint: Codable, Sendable, Equatable, Hashable {
    /// The full 32-byte SHA-256 digest.
    public let rawBytes: Data

    /// Human-readable display: 8 groups of 8 uppercase hex characters, space-separated.
    public var display: String {
        let hex = rawBytes.map { String(format: "%02X", $0) }.joined()
        var groups: [String] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let end = hex.index(idx, offsetBy: 8, limitedBy: hex.endIndex) ?? hex.endIndex
            groups.append(String(hex[idx..<end]))
            idx = end
        }
        return groups.joined(separator: " ")
    }

    /// Derives the fingerprint from a public key by hashing its canonical bytes with SHA-256.
    public init(of publicKey: RemoteIdentityPublicKey) {
        let digest = SHA256.hash(data: publicKey.rawRepresentation)
        self.rawBytes = Data(digest)
    }

    /// Initialises from exactly 32 bytes. Throws if `rawBytes` is not 32 bytes.
    public init(rawBytes: Data) throws {
        guard rawBytes.count == 32 else {
            throw RemoteIdentityPublicKey.Error.invalidLength(expected: 32, actual: rawBytes.count)
        }
        self.rawBytes = rawBytes
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case rawBytes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let data = try container.decode(Data.self, forKey: .rawBytes)
        do {
            try self.init(rawBytes: data)
        } catch RemoteIdentityPublicKey.Error.invalidLength(let expected, let actual) {
            throw DecodingError.dataCorruptedError(
                forKey: .rawBytes,
                in: container,
                debugDescription: "Expected \(expected) bytes, got \(actual)."
            )
        }
    }
}
