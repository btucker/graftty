import Foundation
import GrafttyProtocol
import Testing

@testable import GrafttyKit

@Suite("RemoteMacStore Tests")
struct RemoteMacStoreTests {

    private func makeTempURL() -> URL {
        URL.temporaryDirectory
            .appendingPathComponent("graftty-remote-macs-\(UUID().uuidString).json")
    }

    private func makeFingerprint(_ byte: UInt8 = 0x11) throws -> RemoteIdentityFingerprint {
        try RemoteIdentityFingerprint(rawBytes: Data(repeating: byte, count: 32))
    }

    private func makeRemoteMac(
        id: RemoteDeviceID = RemoteDeviceID(value: "mac-1"),
        label: String = "Studio Mac",
        fingerprintByte: UInt8 = 0x11,
        baseURL: URL? = URL(string: "https://studio.local:9443"),
        addedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        lastUsedAt: Date? = nil,
        lastDiscoveredAt: Date? = nil
    ) throws -> RemoteMac {
        RemoteMac(
            id: id,
            label: label,
            fingerprint: try makeFingerprint(fingerprintByte),
            lastKnownBaseURL: baseURL,
            addedAt: addedAt,
            lastUsedAt: lastUsedAt,
            lastDiscoveredAt: lastDiscoveredAt
        )
    }

    @MainActor
    @Test("add inserts and reloads a saved remote Mac")
    func addInsertsAndReloadsSavedRemoteMac() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let remoteMac = try makeRemoteMac()

        let store = RemoteMacStore(storeURL: url)
        try store.add(remoteMac)

        let reloaded = RemoteMacStore(storeURL: url)
        await reloaded.loadIfNeeded()

        #expect(reloaded.hasLoaded)
        #expect(reloaded.remoteMacs == [remoteMac])
        #expect(try reloaded.get(id: remoteMac.id, fingerprint: remoteMac.fingerprint) == remoteMac)
    }

    @MainActor
    @Test("add updates existing identity instead of duplicating")
    func addUpdatesExistingIdentityInsteadOfDuplicating() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RemoteMacStore(storeURL: url)
        let original = try makeRemoteMac(
            label: "Old Name",
            lastUsedAt: Date(timeIntervalSince1970: 1_700_000_050)
        )
        let updated = try makeRemoteMac(
            label: "New Name",
            baseURL: URL(string: "https://new.local:9443"),
            lastDiscoveredAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        try store.add(original)
        try store.add(updated)

        #expect(store.remoteMacs.count == 1)
        #expect(store.remoteMacs.first?.label == "New Name")
        #expect(store.remoteMacs.first?.lastKnownBaseURL?.absoluteString == "https://new.local:9443")
        #expect(store.remoteMacs.first?.addedAt == original.addedAt)
        #expect(store.remoteMacs.first?.lastUsedAt == original.lastUsedAt)
        #expect(store.remoteMacs.first?.lastDiscoveredAt == updated.lastDiscoveredAt)
    }

    @MainActor
    @Test("partial identity matches do not collapse")
    func partialIdentityMatchesDoNotCollapse() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RemoteMacStore(storeURL: url)
        let original = try makeRemoteMac(id: RemoteDeviceID(value: "same-id"), fingerprintByte: 0x11)
        let changedKey = try makeRemoteMac(id: RemoteDeviceID(value: "same-id"), fingerprintByte: 0x22)
        let reusedKey = try makeRemoteMac(id: RemoteDeviceID(value: "other-id"), fingerprintByte: 0x11)

        try store.add(original)
        try store.add(changedKey)
        try store.add(reusedKey)

        #expect(store.remoteMacs.count == 3)
    }

    @MainActor
    @Test("delete removes only the exact identity tuple")
    func deleteRemovesOnlyExactIdentityTuple() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RemoteMacStore(storeURL: url)
        let original = try makeRemoteMac(id: RemoteDeviceID(value: "same-id"), fingerprintByte: 0x11)
        let changedKey = try makeRemoteMac(id: RemoteDeviceID(value: "same-id"), fingerprintByte: 0x22)

        try store.add(original)
        try store.add(changedKey)
        try store.delete(id: original.id, fingerprint: original.fingerprint)

        #expect(store.remoteMacs == [changedKey])
    }

    @MainActor
    @Test("mutation before async load preserves existing file")
    func mutationBeforeAsyncLoadPreservesExistingFile() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let existing = try makeRemoteMac(
            id: RemoteDeviceID(value: "existing"),
            label: "Existing",
            fingerprintByte: 0x22
        )
        let added = try makeRemoteMac(
            id: RemoteDeviceID(value: "added"),
            label: "Added",
            fingerprintByte: 0x33
        )
        try RemoteMacStore(storeURL: url).add(existing)

        let store = RemoteMacStore(storeURL: url)
        try store.add(added)
        await store.loadIfNeeded()

        #expect(store.hasLoaded)
        #expect(store.remoteMacs.map(\.id).contains(existing.id))
        #expect(store.remoteMacs.map(\.id).contains(added.id))
    }

    @MainActor
    @Test("Protocol v1 remote Macs are discarded and must be paired again")
    func protocolV1RemoteMacsAreDiscarded() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var legacy = try makeRemoteMac(label: "Needs Re-pairing")
        legacy.pairingProtocolVersion = 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([legacy]).write(to: url)

        let store = RemoteMacStore(storeURL: url)
        await store.loadIfNeeded()

        #expect(store.remoteMacs.isEmpty)

        let replacement = try makeRemoteMac(label: "Paired with v2")
        try store.add(replacement)
        #expect(store.remoteMacs == [replacement])
    }

    @MainActor    @Test("""
    @spec REMOTE-12.1: If the saved Remote Macs file exists but cannot be \
    decoded, the application shall move it to a timestamped corruption backup \
    before allowing a later save to create a fresh file.
    """)
    func corruptStoreIsBackedUpBeforeRecoverySave() async throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("graftty-remote-macs-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("remote-macs.json")
        try Data("not-json".utf8).write(to: url)

        let store = RemoteMacStore(storeURL: url)
        await store.loadIfNeeded()

        #expect(store.remoteMacs.isEmpty)
        let backupFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("remote-macs.json.corrupt.") }
        #expect(backupFiles.count == 1)

        try store.add(makeRemoteMac())
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(backupFiles[0]).path
            )
        )
    }

    @Test("connection state has stable raw values")
    func connectionStateHasStableRawValues() throws {
        let encoded = try JSONEncoder().encode(RemoteMacConnectionState.connected)
        let decoded = try JSONDecoder().decode(RemoteMacConnectionState.self, from: encoded)

        #expect(RemoteMacConnectionState.needsPairing.rawValue == "needsPairing")
        #expect(decoded == .connected)
    }
}
