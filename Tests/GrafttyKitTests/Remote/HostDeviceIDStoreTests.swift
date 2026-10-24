import Testing
import Foundation
@testable import GrafttyKit
import GrafttyProtocol
import GrafttyTestSupport

@Suite("HostDeviceIDStore Tests")
struct HostDeviceIDStoreTests {

    @Test("@spec PERSIST-5.13: When host identity stores use their default locations, the application shall store the host key and device ID in the same state directory on every supported platform.")
    func defaultDirectoriesAgree() {
        #expect(HostDeviceIDStore.defaultDirectory == HostIdentityStore.defaultDirectory)
    }

    @Test("loadOrGenerateAndPersist generates once: a second load — including from a fresh store instance — returns the same ID")
    func generatesOnceAndIsStable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HostDeviceIDStore(directory: dir)
        let first = try store.loadOrGenerateAndPersist()
        #expect(!first.value.isEmpty)

        let second = try store.loadOrGenerateAndPersist()
        #expect(second == first)

        // A fresh instance reading the same directory sees the persisted ID.
        let rebooted = HostDeviceIDStore(directory: dir)
        #expect(try rebooted.loadOrGenerateAndPersist() == first)
    }

    @Test("a corrupt device-id file is replaced: loadOrGenerateAndPersist regenerates and the new ID is stable afterwards")
    func corruptFileRegenerates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HostDeviceIDStore(directory: dir)
        let original = try store.loadOrGenerateAndPersist()

        // Corrupt the persisted file.
        let fileURL = dir.appendingPathComponent("host-device-id.json")
        try Data("not json {{{".utf8).write(to: fileURL)

        let regenerated = try HostDeviceIDStore(directory: dir).loadOrGenerateAndPersist()
        #expect(!regenerated.value.isEmpty)
        #expect(regenerated != original)

        // The regenerated ID is persisted and stable from here on.
        #expect(try HostDeviceIDStore(directory: dir).loadOrGenerateAndPersist() == regenerated)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("host-device-id.json.corrupt-") }
        #expect(backups.count == 1)
    }

    // MARK: - On-disk compatibility (#488)

    /// The record shape every shipped release has read and written, frozen
    /// here so a store refactor cannot drift from it unnoticed.
    private struct LegacyStoredID: Decodable {
        struct DeviceID: Decodable { let value: String }
        let version: Int
        let deviceID: DeviceID
    }

    @Test("A host-device-id.json written by earlier releases loads unchanged")
    func loadsFixtureWrittenByEarlierReleases() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = #"{"version":1,"deviceID":{"value":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}}"#
        try Data(fixture.utf8).write(to: dir.appendingPathComponent("host-device-id.json"))

        let loaded = try HostDeviceIDStore(directory: dir).loadOrGenerateAndPersist()
        #expect(loaded == RemoteDeviceID(value: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
    }

    @Test("A host-device-id.json written by the current store decodes with the earlier reader")
    func currentWriterOutputDecodesWithEarlierReader() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try HostDeviceIDStore(directory: dir).loadOrGenerateAndPersist()

        let data = try Data(contentsOf: dir.appendingPathComponent("host-device-id.json"))
        let legacy = try JSONDecoder().decode(LegacyStoredID.self, from: data)
        #expect(legacy.version == 1)
        #expect(legacy.deviceID.value == id.value)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["version", "deviceID"])
    }
}
