#if canImport(UIKit)
import Foundation
import Observation
import Security

/// CRUD store backed by the iOS Keychain, one generic-password item per host.
/// The whole collection lives under a single service name so multiple hosts
/// can share Keychain storage without collision.
@Observable
@MainActor
public final class HostStore {

    public enum StoreError: Error, Equatable {
        case keychain(OSStatus)
        case decode
    }

    public private(set) var hosts: [Host] = []

    private let service: String

    public init(keychainService: String = HostStore.defaultService) {
        self.service = keychainService
        do { hosts = try readAll() } catch { hosts = [] }
    }

    public nonisolated static let defaultService = "net.graftty.GrafttyMobile.hosts"

    public func add(_ host: Host) throws {
        let data = try JSONEncoder().encode(host)
        let attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: host.id.uuidString,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        hosts = try readAll()
    }

    public func update(_ host: Host) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: host.id.uuidString,
        ]
        let data = try JSONEncoder().encode(host)
        let updates: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        hosts = try readAll()
    }

    public func delete(_ id: UUID) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
        hosts = try readAll()
    }

    public func deleteAll() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
        hosts = []
    }

    private func readAll() throws -> [Host] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let datas = out as? [Data] else { throw StoreError.decode }
        let decoder = JSONDecoder()
        return try datas.map { try decoder.decode(Host.self, from: $0) }
            .sorted { ($0.lastUsedAt ?? $0.addedAt) > ($1.lastUsedAt ?? $1.addedAt) }
    }
}
#endif
