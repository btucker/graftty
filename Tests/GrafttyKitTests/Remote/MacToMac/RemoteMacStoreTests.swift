import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

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

    @Test("connection state has stable raw values")
    func connectionStateHasStableRawValues() throws {
        let encoded = try JSONEncoder().encode(RemoteMacConnectionState.connected)
        let decoded = try JSONDecoder().decode(RemoteMacConnectionState.self, from: encoded)

        #expect(RemoteMacConnectionState.needsPairing.rawValue == "needsPairing")
        #expect(decoded == .connected)
    }
}
