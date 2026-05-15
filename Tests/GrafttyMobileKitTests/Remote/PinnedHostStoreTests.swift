import Testing
import Foundation
import CryptoKit

#if canImport(UIKit)
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite("PinnedHostStore Tests")
struct PinnedHostStoreTests {

    func makeTempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func makeHost(
        name: String = "Test Host",
        kind: RemoteDeviceKind = .mac,
        byte: UInt8 = 0x01,
        pinnedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        lastConnectedAt: Date? = nil
    ) -> PinnedHost {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = try! RemoteIdentityPublicKey(rawRepresentation: privateKey.publicKey.rawRepresentation)
        return PinnedHost(
            id: .generate(),
            kind: kind,
            publicKey: publicKey,
            displayName: name,
            pinnedAt: pinnedAt,
            lastConnectedAt: lastConnectedAt,
            pairingURL: URL(string: "https://host.local:8800/v1/pairing")!
        )
    }

    // MARK: - Add and retrieve

    @Test("Add and retrieve a host by ID")
    func addAndRetrieve() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PinnedHostStore(directory: dir)
        let host = makeHost(name: "My Mac")
        try store.add(host)

        let retrieved = try store.get(id: host.id)
        #expect(retrieved != nil)
        #expect(retrieved!.id == host.id)
        #expect(retrieved!.displayName == "My Mac")
    }

    // MARK: - Retrieve by fingerprint

    @Test("get(fingerprint:) retrieves the correct host")
    func getByFingerprint() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PinnedHostStore(directory: dir)
        let host = makeHost(name: "Fingerprint Host")
        try store.add(host)

        let retrieved = try store.get(fingerprint: host.fingerprint)
        #expect(retrieved != nil)
        #expect(retrieved!.id == host.id)
    }

    // MARK: - Update

    @Test("update() changes displayName and pairingURL")
    func updateHost() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PinnedHostStore(directory: dir)
        var host = makeHost(name: "Old Name")
        try store.add(host)

        host.displayName = "New Name"
        host.pairingURL = URL(string: "https://newhost.local:9900/v1/pairing")!
        try store.update(host)

        let retrieved = try store.get(id: host.id)
        #expect(retrieved?.displayName == "New Name")
        #expect(retrieved?.pairingURL.absoluteString == "https://newhost.local:9900/v1/pairing")
    }

    // MARK: - Remove

    @Test("remove() makes the host absent from list and get returns nil")
    func removeHost() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PinnedHostStore(directory: dir)
        let host = makeHost()
        try store.add(host)

        try store.remove(id: host.id)

        let retrieved = try store.get(id: host.id)
        #expect(retrieved == nil)

        let list = try store.list()
        #expect(!list.contains(where: { $0.id == host.id }))
    }

    // MARK: - Duplicate fingerprint rejection

    @Test("add throws duplicateFingerprint when host with same fingerprint is added")
    func rejectsDuplicateFingerprint() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PinnedHostStore(directory: dir)

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = try RemoteIdentityPublicKey(rawRepresentation: privateKey.publicKey.rawRepresentation)

        let host1 = PinnedHost(
            id: .generate(),
            kind: .mac,
            publicKey: publicKey,
            displayName: "Host 1",
            pinnedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pairingURL: URL(string: "https://host1.local:8800/v1/pairing")!
        )
        let host2 = PinnedHost(
            id: .generate(),
            kind: .mac,
            publicKey: publicKey,
            displayName: "Host 2",
            pinnedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pairingURL: URL(string: "https://host2.local:8800/v1/pairing")!
        )

        try store.add(host1)
        #expect(throws: PinnedHostStore.Error.duplicateFingerprint) {
            try store.add(host2)
        }
    }

    // MARK: - List sort order

    @Test("list() returns hosts sorted by lastConnectedAt desc, pinnedAt desc as tiebreak")
    func listSorting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PinnedHostStore(directory: dir)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Host A: connected 1 hour ago
        let hostA = makeHost(name: "A", pinnedAt: base.addingTimeInterval(-7200), lastConnectedAt: base.addingTimeInterval(-3600))
        // Host B: never connected, pinned 2 hours ago
        let hostB = makeHost(name: "B", pinnedAt: base.addingTimeInterval(-7200))
        // Host C: connected most recently (30 min ago)
        let hostC = makeHost(name: "C", pinnedAt: base.addingTimeInterval(-3600), lastConnectedAt: base.addingTimeInterval(-1800))
        // Host D: never connected, pinned 1 hour ago (more recent than B)
        let hostD = makeHost(name: "D", pinnedAt: base.addingTimeInterval(-3600))

        try store.add(hostA)
        try store.add(hostB)
        try store.add(hostC)
        try store.add(hostD)

        let list = try store.list()
        let names = list.map(\.displayName)

        // Expected order: C (connected -30min), A (connected -60min), D (never, pinned -60min), B (never, pinned -120min)
        #expect(names == ["C", "A", "D", "B"], "Expected C, A, D, B — got: \(names)")
    }

    // MARK: - Persistence across instances

    @Test("Stable persistence: a new store on the same directory sees prior adds")
    func stablePersistence() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store1 = PinnedHostStore(directory: dir)
        let host = makeHost(name: "Persistent Host")
        try store1.add(host)

        let store2 = PinnedHostStore(directory: dir)
        let list = try store2.list()
        #expect(list.count == 1)
        #expect(list[0].displayName == "Persistent Host")
        #expect(list[0].id == host.id)
    }

    // MARK: - update throws notFound

    @Test("update throws notFound for unknown host")
    func updateNotFound() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PinnedHostStore(directory: dir)
        let host = makeHost()
        #expect(throws: PinnedHostStore.Error.notFound) {
            try store.update(host)
        }
    }

    // MARK: - remove throws notFound

    @Test("remove throws notFound for unknown host")
    func removeNotFound() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PinnedHostStore(directory: dir)
        #expect(throws: PinnedHostStore.Error.notFound) {
            try store.remove(id: .generate())
        }
    }

    // MARK: - Corruption recovery

    @Test("Corrupt pinned-hosts.json is backed up; list returns empty; recovery add succeeds")
    func corruptFileIsBackedUpAndListReturnsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("pinned-hosts.json")
        try "not json".data(using: .utf8)!.write(to: fileURL)

        let store = PinnedHostStore(directory: dir)

        let list = try store.list()
        #expect(list.isEmpty, "Expected empty list after corrupt file")

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backupFiles = contents.filter { $0.hasPrefix("pinned-hosts.json.corrupt.") }
        #expect(!backupFiles.isEmpty, "Expected a backup file; found: \(contents)")

        let host = makeHost(name: "After Recovery")
        try store.add(host)
        let afterRecovery = try store.list()
        #expect(afterRecovery.count == 1, "Expected one host after recovery add")
        #expect(afterRecovery[0].displayName == "After Recovery")
    }
}
#endif
