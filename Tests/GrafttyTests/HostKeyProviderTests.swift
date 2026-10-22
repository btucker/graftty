import CryptoKit
import Foundation
import Testing
@testable import Graftty

@Suite("@spec REMOTE-1.12: If an earlier host identity load failed and a later load succeeds, the application shall retain the recovered key and use it for both the advertised fingerprint and the inbound host pool.")
@MainActor
struct HostKeyProviderTests {
    private struct LoadFailed: Error {}

    @Test func retainsKeyRecoveredAfterFailedLoad() throws {
        var attempts = 0
        let provider = HostKeyProvider {
            attempts += 1
            if attempts == 1 { throw LoadFailed() }
            return Curve25519.Signing.PrivateKey()
        }

        #expect(throws: LoadFailed.self) { try provider.key() }
        let recovered = try provider.key()
        let later = try provider.key()

        #expect(later.rawRepresentation == recovered.rawRepresentation)
        #expect(attempts == 2)
    }

    @Test func doesNotReloadAfterSuccessfulLoad() throws {
        var attempts = 0
        let provider = HostKeyProvider {
            attempts += 1
            return Curve25519.Signing.PrivateKey()
        }

        let first = try provider.key()
        let second = try provider.key()

        #expect(second.rawRepresentation == first.rawRepresentation)
        #expect(attempts == 1)
    }
}
