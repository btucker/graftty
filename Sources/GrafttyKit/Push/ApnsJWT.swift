import Foundation
import CryptoKit

public enum ApnsJWTError: Error, Equatable {
    case malformedPEM
    case signingFailed
}

public final class ApnsJWT: @unchecked Sendable {
    public let keyID: String
    public let teamID: String

    private let key: P256.Signing.PrivateKey
    private let clock: @Sendable () -> Date

    private let lock = NSLock()
    private var cachedToken: (token: String, issuedAt: Date)?

    public init(privateKeyPEM: String, keyID: String, teamID: String,
                clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.keyID = keyID
        self.teamID = teamID
        self.clock = clock
        do {
            self.key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        } catch {
            throw ApnsJWTError.malformedPEM
        }
    }

    public func token() throws -> String {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        if let cached = cachedToken, now.timeIntervalSince(cached.issuedAt) < 50 * 60 {
            return cached.token
        }
        let header: [String: String] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let payload: [String: Any] = ["iss": teamID, "iat": Int(now.timeIntervalSince1970)]
        let headerSeg = try Self.base64URL(JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let payloadSeg = try Self.base64URL(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let signingInput = "\(headerSeg).\(payloadSeg)"
        let signature = try key.signature(for: Data(signingInput.utf8))
        let sigSeg = Self.base64URL(signature.rawRepresentation)
        let token = "\(signingInput).\(sigSeg)"
        cachedToken = (token, now)
        return token
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
