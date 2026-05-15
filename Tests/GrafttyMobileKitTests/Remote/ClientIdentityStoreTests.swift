import Testing
import Foundation
import CryptoKit

#if canImport(UIKit)
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite("ClientIdentityStore Tests")
struct ClientIdentityStoreTests {

    func makeTempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - First-run generation and stable reload

    @Test("First-run: load() returns nil; generateAndPersist produces a key; reload from new instance returns same key")
    func firstRunGenerationAndStableReload() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store1 = ClientIdentityStore(directory: dir)

        // First run: no key
        let beforeKey = try store1.load()
        #expect(beforeKey == nil, "Expected no key on first run")

        let beforePublicKey = try store1.currentPublicKey()
        #expect(beforePublicKey == nil, "Expected currentPublicKey to be nil before generateAndPersist")

        let generated = try store1.generateAndPersist()

        let afterPublicKey = try store1.currentPublicKey()
        #expect(afterPublicKey != nil, "Expected non-nil after generateAndPersist")

        // Stable reload across store instances
        let store2 = ClientIdentityStore(directory: dir)
        let reloaded = try store2.load()
        #expect(reloaded != nil, "Expected persisted key to be reloadable")
        #expect(reloaded!.rawRepresentation == generated.rawRepresentation)
    }

    // MARK: - loadOrGenerateAndPersist is idempotent

    @Test("loadOrGenerateAndPersist returns the same key on a second call")
    func loadOrGenerateIdempotent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ClientIdentityStore(directory: dir)
        let first = try store.loadOrGenerateAndPersist()
        let second = try store.loadOrGenerateAndPersist()
        #expect(first.rawRepresentation == second.rawRepresentation)
    }

    // MARK: - Reset

    @Test("After reset, load returns nil; generateAndPersist produces a different key")
    func resetClearsPersistedKey() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ClientIdentityStore(directory: dir)
        let original = try store.generateAndPersist()
        try store.reset()

        #expect(try store.load() == nil, "Expected nil after reset")

        let newKey = try store.generateAndPersist()
        #expect(newKey.rawRepresentation != original.rawRepresentation, "Expected a different key after rotation")
    }

    // MARK: - Corruption recovery

    @Test("Corrupt client-identity.json is backed up; load returns nil; recovery succeeds")
    func corruptFileIsBackedUpAndLoadReturnsNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a corrupt file directly
        let fileURL = dir.appendingPathComponent("client-identity.json")
        try "not json".data(using: .utf8)!.write(to: fileURL)

        let store = ClientIdentityStore(directory: dir)

        // load() should return nil without throwing
        let result = try store.load()
        #expect(result == nil, "Expected nil from load() after corrupt file")

        // A backup file must exist
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backupFiles = contents.filter { $0.hasPrefix("client-identity.json.corrupt.") }
        #expect(!backupFiles.isEmpty, "Expected a backup file; found: \(contents)")

        // Recovery: loadOrGenerateAndPersist should succeed
        let newKey = try store.loadOrGenerateAndPersist()
        #expect(newKey.rawRepresentation.count == 32, "Expected a valid new key after corruption recovery")
    }

    // MARK: - 0600 permissions

    @Test("client-identity.json is created with 0600 permissions")
    func persistedFileHas0600Permissions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ClientIdentityStore(directory: dir)
        _ = try store.generateAndPersist()

        let fileURL = dir.appendingPathComponent("client-identity.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let mode = (attrs[.posixPermissions] as? Int) ?? 0
        #expect(mode & 0o777 == 0o600, "Expected 0600 permissions, got \(String(mode, radix: 8))")
    }

    // MARK: - currentPublicKey round-trips

    @Test("currentPublicKey round-trips through RemoteIdentityPublicKey")
    func currentPublicKeyRoundTrips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ClientIdentityStore(directory: dir)
        let privateKey = try store.generateAndPersist()
        let expectedBytes = privateKey.publicKey.rawRepresentation

        let publicKey = try store.currentPublicKey()
        #expect(publicKey != nil)
        #expect(publicKey!.rawRepresentation == expectedBytes)
    }

    // MARK: - Stable persistence across instances

    @Test("Stable persistence: a new store on the same URL sees prior generates")
    func stablePersistenceAcrossInstances() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store1 = ClientIdentityStore(directory: dir)
        let generated = try store1.generateAndPersist()

        let store2 = ClientIdentityStore(directory: dir)
        let reloaded = try store2.load()

        #expect(reloaded != nil)
        #expect(reloaded!.rawRepresentation == generated.rawRepresentation)
    }
}
#endif
