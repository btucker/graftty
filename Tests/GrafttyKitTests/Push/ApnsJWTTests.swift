import Foundation
import CryptoKit
import Testing
@testable import GrafttyKit

@Suite("""
@spec PUSH-3.2: The application shall sign APNs JWTs with ES256 using a `.p8` bundled in Graftty.app at `Resources/apns/AuthKey_<KEYID>.p8`; the same JWT shall be cached for up to 50 minutes before being re-signed.
""")
struct ApnsJWTTests {
    // Throwaway P-256 PEM used for signing tests. Generated with:
    //   openssl ecparam -name prime256v1 -genkey -noout \
    //     | openssl pkcs8 -topk8 -nocrypt
    private let testP8: String = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgnpV8iyPR5CFdcTH6
p0sbFY26LS3Gdb7h9Mo3nExJ7a2hRANCAATnUw6O3bWtU617zFbJx6/0jPXu9ypY
k+UO6SJNap6Zf/DcLRHJhmKBN2PZGiVgwf+UFWTBUMRBdb6V/nshH39t
-----END PRIVATE KEY-----
"""

    @Test func producesThreeSegmentToken() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let signer = try ApnsJWT(privateKeyPEM: testP8, keyID: "KEY123ABCD", teamID: "TEAM67890",
                                 clock: { now })
        let token = try signer.token()
        #expect(token.split(separator: ".").count == 3)
    }

    @Test func reusesTokenWithinFiftyMinutes() throws {
        let virtual = LockedClock(time: Date(timeIntervalSince1970: 1_700_000_000))
        let signer = try ApnsJWT(privateKeyPEM: testP8, keyID: "K", teamID: "T",
                                 clock: { virtual.now })
        let first = try signer.token()
        virtual.advance(by: 49 * 60)
        let second = try signer.token()
        #expect(first == second)
    }

    @Test func mintsNewTokenAfterFiftyMinutes() throws {
        let virtual = LockedClock(time: Date(timeIntervalSince1970: 1_700_000_000))
        let signer = try ApnsJWT(privateKeyPEM: testP8, keyID: "K", teamID: "T",
                                 clock: { virtual.now })
        let first = try signer.token()
        virtual.advance(by: 51 * 60)
        let second = try signer.token()
        #expect(first != second)
    }

    @Test func headerCarriesKeyIDAndAlgorithm() throws {
        let signer = try ApnsJWT(privateKeyPEM: testP8, keyID: "MYKEYID", teamID: "T",
                                 clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        let token = try signer.token()
        let header = token.split(separator: ".")[0]
        let padded = String(header) + String(repeating: "=", count: (4 - header.count % 4) % 4)
        let decoded = Data(base64Encoded: padded.replacingOccurrences(of: "-", with: "+")
                                                .replacingOccurrences(of: "_", with: "/"))!
        let json = try JSONSerialization.jsonObject(with: decoded) as! [String: String]
        #expect(json["alg"] == "ES256")
        #expect(json["kid"] == "MYKEYID")
    }
}

/// Thread-safe mutable clock for tests (Swift 6 strict concurrency: a plain
/// captured `var` inside an `@Sendable` closure won't compile).
final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(time: Date) { _now = time }
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(interval)
    }
}
