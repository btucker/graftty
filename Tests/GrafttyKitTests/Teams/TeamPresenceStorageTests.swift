import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamPresenceStorage — pane-specific records")
struct TeamPresenceStorageTests {
    func makeStorage() throws -> TeamPresenceStorage {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TeamPresenceStorage(rootDirectory: dir)
    }

    @Test("Record round-trips paneSessionName when set.")
    func roundTripsPaneSessionName() throws {
        let storage = try makeStorage()
        let record = TeamPresenceRecord(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            runtime: .codex,
            paneSessionName: "graftty-abc12345",
            pid: 4242,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try storage.write(record)
        let loaded = try #require(storage.listAll().first)
        #expect(loaded.paneSessionName == "graftty-abc12345")
    }

    @Test("Record decodes paneSessionName as nil when field missing (back-compat).")
    func decodesNilWhenFieldMissing() throws {
        let storage = try makeStorage()
        let teamDir = storage.rootDirectory
            .appendingPathComponent(TeamInbox.fileComponent("/repo"), isDirectory: true)
            .appendingPathComponent("presence", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
        let oldJSON = """
        {
          "teamID": "/repo",
          "worktree": "/repo/.worktrees/alice",
          "runtime": "codex",
          "pid": 4242,
          "registeredAt": "2023-11-14T22:13:20Z"
        }
        """
        let leaf = TeamInbox.fileComponent("/repo/.worktrees/alice.codex") + ".json"
        try oldJSON.data(using: .utf8)!.write(to: teamDir.appendingPathComponent(leaf))
        let loaded = try #require(storage.listAll().first)
        #expect(loaded.paneSessionName == nil)
    }
}
