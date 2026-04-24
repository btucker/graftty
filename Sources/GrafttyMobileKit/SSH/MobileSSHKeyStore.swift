#if canImport(UIKit)
import CryptoKit
import Foundation
import Security

public protocol MobileSSHKeyStorage {
    func loadPrivateKey() throws -> Data?
    func savePrivateKey(_ data: Data) throws
}

public final class KeychainMobileSSHKeyStorage: MobileSSHKeyStorage {
    public enum Error: Swift.Error {
        case unexpectedStatus(OSStatus)
    }

    private let service: String
    private let account: String

    public init(
        service: String = "net.graftty.GrafttyMobile.ssh",
        account: String = "generated-client-key"
    ) {
        self.service = service
        self.account = account
    }

    public func loadPrivateKey() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Error.unexpectedStatus(status) }
        return item as? Data
    }

    public func savePrivateKey(_ data: Data) throws {
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.unexpectedStatus(status) }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public final class InMemoryMobileSSHKeyStorage: MobileSSHKeyStorage {
    private var data: Data?

    public init(data: Data? = nil) {
        self.data = data
    }

    public func loadPrivateKey() throws -> Data? { data }
    public func savePrivateKey(_ data: Data) throws { self.data = data }
}

public final class MobileSSHKeyStore {
    private let storage: MobileSSHKeyStorage

    public init(storage: MobileSSHKeyStorage = KeychainMobileSSHKeyStorage()) {
        self.storage = storage
    }

    public func publicKey(comment: String = "graftty-mobile") throws -> String {
        let privateKey = try loadOrGeneratePrivateKey()
        return Self.openSSHPublicKey(for: privateKey.publicKey, comment: comment)
    }

    private func loadOrGeneratePrivateKey() throws -> P256.Signing.PrivateKey {
        if let existing = try storage.loadPrivateKey() {
            return try P256.Signing.PrivateKey(rawRepresentation: existing)
        }
        let key = P256.Signing.PrivateKey()
        try storage.savePrivateKey(key.rawRepresentation)
        return key
    }

    static func openSSHPublicKey(
        for key: P256.Signing.PublicKey,
        comment: String
    ) -> String {
        let algorithm = "ecdsa-sha2-nistp256"
        var blob = Data()
        blob.appendSSHString(algorithm)
        blob.appendSSHString("nistp256")
        blob.appendSSHString(key.x963Representation)
        return "\(algorithm) \(blob.base64EncodedString()) \(comment)"
    }
}

private extension Data {
    mutating func appendSSHString(_ string: String) {
        appendSSHString(Data(string.utf8))
    }

    mutating func appendSSHString(_ data: Data) {
        let length = UInt32(data.count).bigEndian
        Swift.withUnsafeBytes(of: length) { append(contentsOf: $0) }
        append(data)
    }
}
#endif
