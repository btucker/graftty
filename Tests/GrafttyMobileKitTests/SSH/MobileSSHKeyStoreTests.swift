#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite
struct MobileSSHKeyStoreTests {

    @Test
    func generatedPublicKeyUsesOpenSSHFormat() throws {
        let storage = InMemoryMobileSSHKeyStorage()
        let store = MobileSSHKeyStore(storage: storage)

        let publicKey = try store.publicKey()

        #expect(publicKey.hasPrefix("ecdsa-sha2-nistp256 "))
        #expect(publicKey.contains(" graftty-mobile"))
    }

    @Test
    func generatedKeyIsStableAcrossLoads() throws {
        let storage = InMemoryMobileSSHKeyStorage()
        let first = try MobileSSHKeyStore(storage: storage).publicKey()
        let second = try MobileSSHKeyStore(storage: storage).publicKey()

        #expect(first == second)
    }
}
#endif
