import Testing
import Foundation
import CryptoKit
@testable import GrafttyKit
import GrafttyProtocol

@Suite("HostIdentityStore Tests")
struct HostIdentityStoreTests {

    func makeTempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - REMOTE-1.1 (promoted from RemoteTodo.swift)

    @Test("""
    @spec REMOTE-1.1: When a host starts remote access for the first time, the application shall generate and persist a host identity key before accepting pairing requests.
    """)
    func firstRunGenerationAndStableReload() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store1 = HostIdentityStore(directory: dir)

        // First run: no key persisted yet
        let loaded = try store1.load()
        #expect(loaded == nil, "Expected no key on first run")

        // currentPublicKey() returns nil before any generation
        let beforeKey = try store1.currentPublicKey()
        #expect(beforeKey == nil, "Expected currentPublicKey to be nil before generateAndPersist")

        // Generate and persist
        let generated = try store1.generateAndPersist()

        // After generation, currentPublicKey() is non-nil
        let afterKey = try store1.currentPublicKey()
        #expect(afterKey != nil, "Expected currentPublicKey to be non-nil after generateAndPersist")

        // Stable reload: a fresh store on the same directory loads the same key bytes
        let store2 = HostIdentityStore(directory: dir)
        let reloaded = try store2.load()
        #expect(reloaded != nil, "Expected key to be persisted")
        #expect(reloaded!.rawRepresentation == generated.rawRepresentation,
                "Reloaded key should have same bytes as generated key")
    }

    // MARK: - Additional coverage tests

    @Test("Generated key has expected 32-byte raw representation size")
    func generatedKeySize() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HostIdentityStore(directory: dir)
        let key = try store.generateAndPersist()
        #expect(key.rawRepresentation.count == 32)
    }

    @Test("loadOrGenerateAndPersist returns existing key on second call")
    func loadOrGenerateIdempotent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HostIdentityStore(directory: dir)
        let first = try store.loadOrGenerateAndPersist()
        let second = try store.loadOrGenerateAndPersist()
        #expect(first.rawRepresentation == second.rawRepresentation)
    }

    @Test("After reset, load returns nil and generateAndPersist produces a different key")
    func resetClearsPersistedKey() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HostIdentityStore(directory: dir)
        let original = try store.generateAndPersist()
        let originalBytes = original.rawRepresentation

        try store.reset()

        #expect(try store.load() == nil, "Expected nil after reset")

        let newKey = try store.generateAndPersist()
        // Collision probability is 1 in 2^256.
        #expect(newKey.rawRepresentation != originalBytes, "Expected a different key after rotation")
    }

    @Test("Corrupt host-identity.json is backed up and load returns nil without throwing")
    func corruptFileIsBackedUpAndLoadReturnsNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a corrupt file directly
        let fileURL = dir.appendingPathComponent("host-identity.json")
        try "not json".data(using: .utf8)!.write(to: fileURL)

        let store = HostIdentityStore(directory: dir)

        // load() should return nil, not throw
        let result = try store.load()
        #expect(result == nil, "Expected nil from load() after corrupt file")

        // A backup file with .corrupt.<digits> suffix should exist
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backupFiles = contents.filter { $0.hasPrefix("host-identity.json.corrupt.") }
        #expect(!backupFiles.isEmpty, "Expected a backup file to exist; found: \(contents)")

        // loadOrGenerateAndPersist should succeed and return a new key
        let newKey = try store.loadOrGenerateAndPersist()
        #expect(newKey.rawRepresentation.count == 32, "Expected a valid new key after corruption recovery")
    }

    @Test("host-identity.json is created with 0600 permissions")
    func persistedFileHas0600Permissions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HostIdentityStore(directory: dir)
        _ = try store.generateAndPersist()

        let fileURL = dir.appendingPathComponent("host-identity.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let mode = (attrs[.posixPermissions] as? Int) ?? 0
        #expect(mode & 0o777 == 0o600, "Expected 0600 permissions, got \(String(mode, radix: 8))")
    }

    @Test("currentPublicKey round-trips through RemoteIdentityPublicKey")
    func currentPublicKeyRoundTrips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HostIdentityStore(directory: dir)
        let privateKey = try store.generateAndPersist()
        let expectedBytes = privateKey.publicKey.rawRepresentation

        let publicKey = try store.currentPublicKey()
        #expect(publicKey != nil)
        #expect(publicKey!.rawRepresentation == expectedBytes)
    }

    @Test("Stable persistence across store instances")
    func stablePersistenceAcrossInstances() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store1 = HostIdentityStore(directory: dir)
        let generated = try store1.generateAndPersist()

        // Second instance, same directory
        let store2 = HostIdentityStore(directory: dir)
        let reloaded = try store2.load()

        #expect(reloaded != nil)
        #expect(reloaded!.rawRepresentation == generated.rawRepresentation)
    }
}
