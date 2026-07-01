import Testing
import Foundation
@testable import GrafttyKit
import GrafttyProtocol

@Suite("HostDeviceIDStore Tests")
struct HostDeviceIDStoreTests {

    private func makeTempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
    }
}
