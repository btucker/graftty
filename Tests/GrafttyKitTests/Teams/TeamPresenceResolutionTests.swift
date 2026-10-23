import Foundation
import Testing
@testable import GrafttyKit

@Suite("Team presence resolution")
struct TeamPresenceResolutionTests {
    @Test("Presence resolution returns the canonical worktree path for delivery ownership.")
    func presenceResolutionReturnsCanonicalWorktreePath() throws {
        let state = AppState(repos: [
            RepoEntry(path: "/repo", displayName: "repo", worktrees: [
                WorktreeEntry(path: "/repo", branch: "main"),
                WorktreeEntry(path: "/repo/.worktrees/alice", branch: "alice"),
            ]),
        ])

        let resolved = try #require(TeamPresenceResolution.resolveTeamAndWorktree(
            state: state,
            worktreePath: "/repo/.worktrees/alice"
        ))

        #expect(TeamLookup.id(of: resolved.team) == "/repo")
        #expect(resolved.worktreePath == "/repo/.worktrees/alice")
        #expect(resolved.memberName == "alice")
    }

    @Test("Presence migration removes legacy member-name keyed records.")
    func presenceMigrationRemovesLegacyMemberNameRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = TeamPresenceStorage(rootDirectory: dir)
        let registeredAt = Date(timeIntervalSince1970: 1_700_000_000)
        try storage.write(.init(
            teamID: "/repo", worktree: "alice", runtime: .codex,
            paneSessionName: "graftty-aaaaaaaa", pid: 1,
            processStartTimeMicroseconds: nil, registeredAt: registeredAt
        ))
        let resolved = TeamPresenceResolution.Resolved(
            team: TeamView(repoPath: "/repo", repoDisplayName: "repo", members: []),
            worktreePath: "/repo/.worktrees/alice",
            memberName: "alice"
        )

        let prior = try TeamPresenceResolution.deleteLegacyMemberNamePresence(
            storage: storage,
            teamID: "/repo",
            resolved: resolved,
            runtime: .codex,
            paneSessionName: "graftty-aaaaaaaa"
        )

        #expect(prior?.worktree == "alice")
        #expect(try storage.read(
            teamID: "/repo",
            worktree: "alice",
            runtime: .codex,
            paneSessionName: "graftty-aaaaaaaa"
        ) == nil)
    }
}
