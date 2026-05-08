import Foundation
import Testing
@testable import GrafttyKit

@Suite("graftty team register — pane resolution")
struct TeamRegisterCLITests {
    @Test("@spec TEAM-IDLE-2.9: When ZMX_SESSION is set, the recorded paneSessionName equals it.")
    func paneSessionNameFromZmxSession() {
        let env = ["ZMX_SESSION": "graftty-abc12345"]
        let resolved = TeamRegisterPaneResolver.paneSessionName(env: env)
        #expect(resolved == "graftty-abc12345")
    }

    @Test("@spec TEAM-IDLE-2.10: When ZMX_SESSION is unset, the recorded paneSessionName is nil.")
    func paneSessionNameNilWhenUnset() {
        let env: [String: String] = [:]
        let resolved = TeamRegisterPaneResolver.paneSessionName(env: env)
        #expect(resolved == nil)
    }

    @Test("Empty ZMX_SESSION is treated as unset.")
    func paneSessionNameNilWhenEmpty() {
        let env = ["ZMX_SESSION": ""]
        let resolved = TeamRegisterPaneResolver.paneSessionName(env: env)
        #expect(resolved == nil)
    }

    @Test("@spec TEAM-IDLE-2.13: Unregister with ZMX_SESSION set targets only that pane's record.")
    func unregisterWithZmxSessionDeletesOnlyMatchingRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storage = TeamPresenceStorage(rootDirectory: dir)
        let registeredAt = Date(timeIntervalSince1970: 1_700_000_000)
        try storage.write(.init(
            teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
            paneSessionName: "graftty-aaaaaaaa", pid: 1, registeredAt: registeredAt
        ))
        try storage.write(.init(
            teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
            paneSessionName: "graftty-bbbbbbbb", pid: 2, registeredAt: registeredAt
        ))

        try TeamUnregisterCore.unregister(
            storage: storage,
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            runtime: .codex,
            paneSessionName: "graftty-aaaaaaaa"
        )

        let surviving = try storage.listAll()
        #expect(surviving.count == 1)
        #expect(surviving.first?.paneSessionName == "graftty-bbbbbbbb")
    }
}
