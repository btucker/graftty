import Foundation
import Security
import GrafttyProtocol

/// Device-local Keychain storage for the listener identity and per-pair route hints.
public enum TailcatCredentials {
    public static func endpoint(for fingerprint: RemoteIdentityFingerprint) throws -> TailcatEndpoint? {
        try load(TailcatEndpoint.self, account: "paired-" + fingerprint.display)
    }

    public static func saveEndpoint(_ endpoint: TailcatEndpoint?, for fingerprint: RemoteIdentityFingerprint) throws {
        let account = "paired-" + fingerprint.display
        if let endpoint {
            try save(endpoint, account: account)
        } else {
            try remove(account: account)
        }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.quotably.graftty.tailcat",
         kSecAttrAccount as String: account]
    }

    public static func load<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        var request = query(account)
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(type, from: data)
    }

    public static func save<T: Encodable>(_ value: T, account: String) throws {
        let key = query(account)
        let data = try JSONEncoder().encode(value)
        var entry = key
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        entry[kSecValueData as String] = data
        var status = SecItemAdd(entry as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(key as CFDictionary, [kSecValueData: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private static func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private struct KeychainError: Error { let status: OSStatus }
}
