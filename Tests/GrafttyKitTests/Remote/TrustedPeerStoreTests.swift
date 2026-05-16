import Testing
import Foundation
import CryptoKit
@testable import GrafttyKit
import GrafttyProtocol

@Suite("TrustedPeerStore Tests")
struct TrustedPeerStoreTests {

    func makeTempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func makePeer(
        name: String = "Test Device",
        kind: RemoteDeviceKind = .iphone,
        lastSeenAt: Date? = nil,
        pairedAt: Date = Date()
    ) -> TrustedPeer {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = try! RemoteIdentityPublicKey(rawRepresentation: privateKey.publicKey.rawRepresentation)
        return TrustedPeer(
            id: .generate(),
            kind: kind,
            publicKey: publicKey,
            displayName: name,
            capabilities: .defaultsAfterPairing,
            pairedAt: pairedAt,
            lastSeenAt: lastSeenAt
        )
    }

    // MARK: - Add and retrieve

    @Test("Add and retrieve a peer by ID")
    func addAndRetrieve() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TrustedPeerStore(directory: dir)
        let peer = makePeer(name: "My iPhone")

        try store.add(peer)

        let retrieved = try store.get(id: peer.id)
        #expect(retrieved != nil)
        #expect(retrieved!.id == peer.id)
        #expect(retrieved!.displayName == "My iPhone")
    }

    // MARK: - Update

    @Test("Update capabilities and displayName via update()")
    func updateCapabilitiesAndDisplayName() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TrustedPeerStore(directory: dir)
        var peer = makePeer(name: "Old Name")
        try store.add(peer)

        peer.displayName = "New Name"
        peer.capabilities = PairedDeviceCapabilities(
            terminalControl: .allowed,
            portTunnel: .allowedLoopback,
            screenView: .allowed,
            screenControl: .disabled
        )
        try store.update(peer)

        let retrieved = try store.get(id: peer.id)
        #expect(retrieved?.displayName == "New Name")
        #expect(retrieved?.capabilities.portTunnel == .allowedLoopback)
        #expect(retrieved?.capabilities.screenView == .allowed)
    }

    // MARK: - Revoke

    @Test("Revoke (remove) a peer makes it absent from list and get returns nil")
    func revokePeer() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TrustedPeerStore(directory: dir)
        let peer = makePeer()
        try store.add(peer)

        try store.remove(id: peer.id)

        let retrieved = try store.get(id: peer.id)
        #expect(retrieved == nil)

        let list = try store.list()
        #expect(!list.contains(where: { $0.id == peer.id }))
    }

    // MARK: - Duplicate fingerprint rejection

    @Test("add throws duplicateFingerprint when peer with same fingerprint is added")
    func rejectsDuplicateFingerprint() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TrustedPeerStore(directory: dir)

        // Create two peers that share the same public key (same fingerprint)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = try RemoteIdentityPublicKey(rawRepresentation: privateKey.publicKey.rawRepresentation)

        let peer1 = TrustedPeer(
            id: .generate(),
            kind: .iphone,
            publicKey: publicKey,
            displayName: "Device 1",
            capabilities: .defaultsAfterPairing,
            pairedAt: Date(),
            lastSeenAt: nil
        )
        let peer2 = TrustedPeer(
            id: .generate(),
            kind: .ipad,
            publicKey: publicKey,
            displayName: "Device 2",
            capabilities: .defaultsAfterPairing,
            pairedAt: Date(),
            lastSeenAt: nil
        )

        try store.add(peer1)

        #expect(throws: TrustedPeerStore.Error.duplicateFingerprint) {
            try store.add(peer2)
        }
    }

    // MARK: - List sorting

    @Test("list() returns peers sorted by lastSeenAt desc, with pairedAt desc as tiebreak")
    func listSorting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TrustedPeerStore(directory: dir)
        let now = Date()

        // peer A: seen 1 hour ago
        let peerA = makePeer(name: "A", lastSeenAt: now.addingTimeInterval(-3600), pairedAt: now.addingTimeInterval(-7200))
        // peer B: never seen (nil lastSeenAt), paired 2 hours ago
        let peerB = makePeer(name: "B", lastSeenAt: nil, pairedAt: now.addingTimeInterval(-7200))
        // peer C: seen most recently (30 minutes ago)
        let peerC = makePeer(name: "C", lastSeenAt: now.addingTimeInterval(-1800), pairedAt: now.addingTimeInterval(-3600))
        // peer D: never seen (nil lastSeenAt), paired 1 hour ago (more recent than B)
        let peerD = makePeer(name: "D", lastSeenAt: nil, pairedAt: now.addingTimeInterval(-3600))

        try store.add(peerA)
        try store.add(peerB)
        try store.add(peerC)
        try store.add(peerD)

        let list = try store.list()
        let names = list.map(\.displayName)

        // Expected order: C (seen -30min), A (seen -60min), D (never seen, paired -60min), B (never seen, paired -120min)
        #expect(names == ["C", "A", "D", "B"],
                "Expected sort: C, A, D, B — got: \(names)")
    }

    // MARK: - contains(fingerprint:)

    @Test("contains(fingerprint:) returns true for present peer, false otherwise")
    func containsFingerprint() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TrustedPeerStore(directory: dir)
        let peer = makePeer()
        let fp = peer.fingerprint

        #expect(try store.contains(fingerprint: fp) == false)

        try store.add(peer)

        #expect(try store.contains(fingerprint: fp) == true)

        // A different key's fingerprint should not be found
        let otherPeer = makePeer()
        #expect(try store.contains(fingerprint: otherPeer.fingerprint) == false)
    }

    // MARK: - Stable persistence

    @Test("Stable persistence: a new store on the same URL sees prior adds")
    func stablePersistence() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store1 = TrustedPeerStore(directory: dir)
        let peer = makePeer(name: "Persistent Device")
        try store1.add(peer)

        let store2 = TrustedPeerStore(directory: dir)
        let list = try store2.list()
        #expect(list.count == 1)
        #expect(list[0].displayName == "Persistent Device")
        #expect(list[0].id == peer.id)
    }

    // MARK: - update throws notFound

    @Test("update throws notFound for unknown peer")
    func updateNotFound() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TrustedPeerStore(directory: dir)
        let peer = makePeer()

        #expect(throws: TrustedPeerStore.Error.notFound) {
            try store.update(peer)
        }
    }

    // MARK: - remove throws notFound

    @Test("remove throws notFound for unknown peer")
    func removeNotFound() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TrustedPeerStore(directory: dir)

        #expect(throws: TrustedPeerStore.Error.notFound) {
            try store.remove(id: .generate())
        }
    }

    // MARK: - Missing file is not corruption

    @Test("Missing trusted-peers.json returns empty list without creating a .corrupt backup")
    func missingFileReturnsEmptyWithoutCorruptBackup() throws {
        // Use a directory that exists but has no peers file in it.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TrustedPeerStore(directory: dir)

        // list() on a never-written store must return [], not throw
        let list = try store.list()
        #expect(list.isEmpty, "Expected empty list when file has never been written")

        // Crucially: no .corrupt backup should be created
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backupFiles = contents.filter { $0.hasPrefix("trusted-peers.json.corrupt.") }
        #expect(backupFiles.isEmpty, "A missing file must NOT create a .corrupt backup; found: \(contents)")
    }

    // MARK: - Corruption recovery

    @Test("Corrupt trusted-peers.json is backed up and list returns empty without throwing")
    func corruptFileIsBackedUpAndListReturnsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a corrupt file directly
        let fileURL = dir.appendingPathComponent("trusted-peers.json")
        try "not json".data(using: .utf8)!.write(to: fileURL)

        let store = TrustedPeerStore(directory: dir)

        // list() should return empty, not throw
        let list = try store.list()
        #expect(list.isEmpty, "Expected empty list after corrupt file")

        // A backup file with .corrupt.<digits> suffix should exist
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backupFiles = contents.filter { $0.hasPrefix("trusted-peers.json.corrupt.") }
        #expect(!backupFiles.isEmpty, "Expected a backup file to exist; found: \(contents)")

        // add() should succeed; subsequent list() shows the added peer
        let peer = makePeer(name: "After Recovery")
        try store.add(peer)
        let afterRecovery = try store.list()
        #expect(afterRecovery.count == 1, "Expected one peer after recovery add")
        #expect(afterRecovery[0].displayName == "After Recovery")
    }
}
