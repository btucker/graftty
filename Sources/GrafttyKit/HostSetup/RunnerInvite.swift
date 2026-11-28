#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation
import GrafttyProtocol

public enum RunnerInviteError: Error, LocalizedError, Sendable, Equatable {
    case malformed
    public var errorDescription: String? {
        switch self {
        case .malformed: return "This is not a valid Graftty runner invite. Run graftty-runner invite again and paste the whole line."
        }
    }
}

/// One line a runner prints so a Mac can add it without inbound access. It
/// carries the runner's public identity, its Tailcat endpoint, and a one-time
/// enrollment secret. The endpoint and secret are secrets: never log either.
///
/// @spec REMOTE-33.7
public struct RunnerInvite: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let prefix = "graftty-invite-1:"

    public let identity: LinuxHostIdentity
    public let endpoint: TailcatEndpoint
    public let secret: Data
    public let expiresAt: Date

    public var description: String { "RunnerInvite(\(identity.displayName), redacted)" }
    public var debugDescription: String { description }

    public init(identity: LinuxHostIdentity, endpoint: TailcatEndpoint, secret: Data, expiresAt: Date) {
        self.identity = identity
        self.endpoint = endpoint
        self.secret = secret
        self.expiresAt = expiresAt
    }

    public func encoded() -> String {
        Self.prefix + RunnerInviteCoding.encode(self)
    }

    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix),
              let invite = RunnerInviteCoding.decode(Self.self, from: trimmed.dropFirst(Self.prefix.count)),
              invite.secret.count == RunnerInviteBook.secretLength,
              !invite.endpoint.address.isEmpty,
              (try? invite.identity.validate()) != nil else { throw RunnerInviteError.malformed }
        self = invite
    }

    public static func looksLikeInvite(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix)
    }
}

/// The SSH username a Mac sends, signed with its own key, to redeem an invite.
public struct RunnerEnrollmentToken: Codable, Sendable, Equatable, CustomStringConvertible {
    public static let prefix = "graftty-enroll-1:"

    public let secret: Data
    public let deviceID: String
    public let displayName: String

    public var description: String { "RunnerEnrollmentToken(\(displayName), redacted)" }

    public init(secret: Data, deviceID: String, displayName: String) {
        self.secret = secret
        self.deviceID = deviceID
        self.displayName = displayName
    }

    public var username: String { Self.prefix + RunnerInviteCoding.encode(self) }

    public init?(username: String) {
        guard username.hasPrefix(Self.prefix),
              let token = RunnerInviteCoding.decode(Self.self, from: username.dropFirst(Self.prefix.count)),
              token.secret.count == RunnerInviteBook.secretLength, !token.deviceID.isEmpty, !token.displayName.isEmpty
        else { return nil }
        self = token
    }
}

/// Outstanding invite secrets, held in memory only: a restart cancels them.
/// Each secret is stored as its SHA-256 digest and redeems at most once.
public final class RunnerInviteBook: @unchecked Sendable {
    public static let secretLength = 32
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var outstanding: [(digest: Data, expiresAt: Date)] = []

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    /// A new secret and its expiry.
    public func issue(lifetime: TimeInterval = 3600) -> (secret: Data, expiresAt: Date) {
        var generator = SystemRandomNumberGenerator()
        let secret = Data((0..<Self.secretLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let expiresAt = now().addingTimeInterval(lifetime)
        lock.withLock {
            prune()
            outstanding.append((Self.digest(secret), expiresAt))
        }
        return (secret, expiresAt)
    }

    /// True once for an unexpired secret this book issued.
    public func redeem(_ secret: Data) -> Bool {
        let candidate = Self.digest(secret)
        return lock.withLock {
            prune()
            var match: Int?
            for (index, entry) in outstanding.enumerated() where Self.constantTimeEqual(entry.digest, candidate) {
                match = index
            }
            guard let match else { return false }
            outstanding.remove(at: match)
            return true
        }
    }

    private func prune() {
        let current = now()
        outstanding.removeAll { $0.expiresAt <= current }
    }

    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Base64url without padding over sorted-key JSON, with whole-second dates.
enum RunnerInviteCoding {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        // Encoding these value types cannot fail.
        let data = (try? encoder.encode(value)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: Substring) -> T? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }
}
