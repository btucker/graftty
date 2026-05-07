import XCTest
@testable import Graftty
@testable import GrafttyKit

final class TeamActivityLogWindowIDTests: XCTestCase {
    /// @spec TEAM-7.1: When the user invokes the *Window → Team
    /// Activity Log* command, the application shall open the Team
    /// Activity Log window for the focused worktree's team — and shall
    /// disable the command when the focused selection has no team
    /// (single-worktree repo, no selection, or `agentTeamsEnabled`
    /// off).
    func testFocusedTeamIDResolvesOnlyForTeamEnabledFocusedWorktree() {
        let repo = teamRepoFixture()

        // Happy path: focused worktree has a team and teams are enabled.
        let resolved = TeamActivityLogWindowID.focusedTeamID(
            selectedWorktreePath: repo.worktrees[1].path,
            repos: [repo],
            agentTeamsEnabled: true
        )
        XCTAssertEqual(resolved?.teamID, repo.path)
        XCTAssertEqual(resolved?.teamName, repo.displayName)

        // Disabled: agentTeamsEnabled = false.
        XCTAssertNil(TeamActivityLogWindowID.focusedTeamID(
            selectedWorktreePath: repo.worktrees[1].path,
            repos: [repo],
            agentTeamsEnabled: false
        ))

        // Disabled: nothing focused.
        XCTAssertNil(TeamActivityLogWindowID.focusedTeamID(
            selectedWorktreePath: nil,
            repos: [repo],
            agentTeamsEnabled: true
        ))

        // Disabled: focused worktree's repo has only one worktree
        // (TEAM-2.1 — single-worktree repos have no team).
        let solo = soloRepoFixture()
        XCTAssertNil(TeamActivityLogWindowID.focusedTeamID(
            selectedWorktreePath: solo.worktrees[0].path,
            repos: [solo],
            agentTeamsEnabled: true
        ))
    }

    /// @spec TEAM-7.2: Right-clicking a team-enabled worktree row in
    /// the sidebar shall include a *Show Team Activity…* item that
    /// opens the activity-log window for that team. The routing key
    /// derives from the same `(teamID, teamName)` pair the Window menu
    /// command uses, so both entry points target the same per-team
    /// `WindowGroup` instance.
    func testWindowIDIsHashableAndCodableForSwiftUIRouting() throws {
        let id1 = TeamActivityLogWindowID(teamID: "/repo/foo", teamName: "foo")
        let id2 = TeamActivityLogWindowID(teamID: "/repo/foo", teamName: "foo")
        let id3 = TeamActivityLogWindowID(teamID: "/repo/bar", teamName: "bar")

        XCTAssertEqual(id1, id2)
        XCTAssertNotEqual(id1, id3)
        XCTAssertEqual(id1.hashValue, id2.hashValue)

        let data = try JSONEncoder().encode(id1)
        let decoded = try JSONDecoder().decode(TeamActivityLogWindowID.self, from: data)
        XCTAssertEqual(id1, decoded)

        XCTAssertEqual(TeamActivityLogWindowID.windowGroupID, "team-activity-log")
    }

    // MARK: - Fixtures

    private func teamRepoFixture() -> RepoEntry {
        var repo = RepoEntry(path: "/repo/team", displayName: "team")
        repo.worktrees = [
            WorktreeEntry(path: "/repo/team", branch: "main", state: .running),
            WorktreeEntry(path: "/repo/team/.worktrees/feature", branch: "feature", state: .running),
        ]
        return repo
    }

    private func soloRepoFixture() -> RepoEntry {
        var repo = RepoEntry(path: "/repo/solo", displayName: "solo")
        repo.worktrees = [
            WorktreeEntry(path: "/repo/solo", branch: "main", state: .running),
        ]
        return repo
    }
}
