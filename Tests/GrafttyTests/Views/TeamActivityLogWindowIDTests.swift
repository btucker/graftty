import XCTest
@testable import Graftty
@testable import GrafttyKit

final class TeamActivityLogWindowIDTests: XCTestCase {
    /// @spec TEAM-7.1: When the user invokes the Window → Team Activity Log command, the application shall open the focused tracked repository's Team Activity Log, including repositories with one worktree, and shall disable the command when no tracked worktree is focused or agent teams are disabled.
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

        // A single-worktree repository has a team and an activity log.
        let solo = soloRepoFixture()
        XCTAssertEqual(
            TeamActivityLogWindowID.focusedTeamID(
                selectedWorktreePath: solo.worktrees[0].path,
                repos: [solo],
                agentTeamsEnabled: true
            ),
            TeamActivityLogWindowID(teamID: solo.path, teamName: solo.displayName)
        )
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
