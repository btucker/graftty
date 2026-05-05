import Testing
import Foundation
@testable import GrafttyKit

@Suite("TeamPresence — registration and storage")
struct TeamPresenceTests {
    @Test("@spec TEAM-PRESENCE-1.2: When the agent runs `graftty team register`, the application shall persist a presence record at `~/.graftty/teams/<id>/presence/<worktree>.<runtime>.json`.")
    func registerPersistsRecord() throws {
        let tmpRoot = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let storage = TeamPresenceStorage(rootDirectory: tmpRoot)
        let record = TeamPresenceRecord(
            teamID: "team-abc",
            worktree: "feature-foo",
            runtime: .claude,
            pid: 4242,
            registeredAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        try storage.write(record)

        // Behaviorally enforce the on-disk path layout the spec promises.
        let expectedPath = tmpRoot
            .appendingPathComponent("team-abc")
            .appendingPathComponent("presence")
            .appendingPathComponent("feature-foo.claude.json")
        #expect(FileManager.default.fileExists(atPath: expectedPath.path))

        let loaded = try storage.read(teamID: "team-abc", worktree: "feature-foo", runtime: .claude)
        #expect(loaded == record)
    }

    @Test("Unregister removes the presence record and is idempotent on missing files.")
    func unregisterIsIdempotent() throws {
        let tmpRoot = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let storage = TeamPresenceStorage(rootDirectory: tmpRoot)

        // Removing nothing succeeds.
        try storage.delete(teamID: "team-abc", worktree: "feature-foo", runtime: .claude)

        // Round-trip then delete.
        let record = TeamPresenceRecord(
            teamID: "team-abc",
            worktree: "feature-foo",
            runtime: .claude,
            pid: 4242,
            registeredAt: Date()
        )
        try storage.write(record)
        try storage.delete(teamID: "team-abc", worktree: "feature-foo", runtime: .claude)

        let loaded = try storage.read(teamID: "team-abc", worktree: "feature-foo", runtime: .claude)
        #expect(loaded == nil)
    }

    @Test("Reading a non-existent record returns nil rather than throwing.")
    func readMissingReturnsNil() throws {
        let tmpRoot = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let storage = TeamPresenceStorage(rootDirectory: tmpRoot)

        let result = try storage.read(teamID: "x", worktree: "y", runtime: .codex)
        #expect(result == nil)
    }

    private func makeTmpDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-presence-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
