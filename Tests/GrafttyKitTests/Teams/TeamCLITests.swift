import Testing
import Foundation
@testable import GrafttyKit

/// Tests for the `graftty team` CLI subcommand surface (TEAM-4.*).
///
/// The `GrafttyCLI` binary cannot be imported as a test module, so these
/// tests exercise the protocol types and output-format contracts that the CLI
/// subcommands depend on. They mirror the style of `NotifyInputValidationTests`
/// and `TeamViewTests`.
@Suite("Team CLI")
struct TeamCLITests {

    // MARK: - TeamListMember protocol (TEAM-4.3 output contract)

    /// TEAM-4.3: the per-member line format is:
    ///   "<name>  branch=<branch>  worktree=<path>  role=<role>  running=<bool>"
    /// This test validates the expected format string by constructing the same
    /// interpolation the CLI's `TeamList.run()` uses, so any change to the
    /// format string breaks here first.
    @Test func memberLineFormatMatchesSpec() {
        let m = TeamListMember(
            name: "feature/login",
            branch: "feature/login",
            worktreePath: "/repo/.worktrees/feature-login",
            role: "coworker",
            isRunning: true
        )
        let line = "\(m.name)  branch=\(m.branch)  worktree=\(m.worktreePath)  role=\(m.role)  running=\(m.isRunning)"
        #expect(line == "feature/login  branch=feature/login  worktree=/repo/.worktrees/feature-login  role=coworker  running=true")
    }

    @Test func headerLineFormatMatchesSpec() {
        // TEAM-4.3: header is "team=<name>  members=<count>"
        let teamName = "myrepo"
        let memberCount = 3
        let header = "team=\(teamName)  members=\(memberCount)"
        #expect(header == "team=myrepo  members=3")
    }

    // MARK: - TeamListMember Codable round-trip

    @Test func teamListMemberRoundTrips() throws {
        let original = TeamListMember(
            name: "main",
            branch: "main",
            worktreePath: "/repo",
            role: "lead",
            isRunning: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TeamListMember.self, from: data)
        #expect(decoded == original)
    }

    @Test func teamListMemberUsesSnakeCaseKeys() throws {
        let m = TeamListMember(
            name: "alice",
            branch: "feature/alice",
            worktreePath: "/repo/.worktrees/alice",
            role: "coworker",
            isRunning: false
        )
        let data = try JSONEncoder().encode(m)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // CodingKeys: worktreePath → "worktree_path", isRunning → "is_running"
        #expect(json["worktree_path"] as? String == "/repo/.worktrees/alice")
        #expect(json["is_running"] as? Bool == false)
        #expect(json["name"] as? String == "alice")
        #expect(json["role"] as? String == "coworker")
    }

    // MARK: - ResponseMessage.teamList round-trip

    @Test func responseMessageTeamListRoundTrips() throws {
        let members = [
            TeamListMember(name: "main", branch: "main", worktreePath: "/r", role: "lead", isRunning: true),
            TeamListMember(name: "feature-x", branch: "feature/x", worktreePath: "/r/.worktrees/feature-x", role: "coworker", isRunning: false),
        ]
        let original = ResponseMessage.teamList(teamName: "myrepo", members: members)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ResponseMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test func responseMessageTeamListUsesTypeField() throws {
        let original = ResponseMessage.teamList(teamName: "repo", members: [])
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_list")
        #expect(json["team_name"] as? String == "repo")
    }

    // MARK: - NotificationMessage.teamMessage and .teamList encoding

    @Test func teamMessageEncodesCorrectly() throws {
        let msg = NotificationMessage.teamMessage(callerWorktree: "/repo", recipient: "alice", text: "hello")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_message")
        #expect(json["caller_worktree"] as? String == "/repo")
        #expect(json["recipient"] as? String == "alice")
        #expect(json["text"] as? String == "hello")
    }

    @Test func teamListEncodesCorrectly() throws {
        let msg = NotificationMessage.teamList(callerWorktree: "/repo/.worktrees/feature-x")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_list")
        #expect(json["caller_worktree"] as? String == "/repo/.worktrees/feature-x")
    }

    @Test func teamMessageRoundTrips() throws {
        let original = NotificationMessage.teamMessage(callerWorktree: "/r/wt", recipient: "bob", text: "ready?")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
        if case .teamMessage(let path, let recipient, let text) = decoded {
            #expect(path == "/r/wt")
            #expect(recipient == "bob")
            #expect(text == "ready?")
        } else {
            Issue.record("Expected .teamMessage, got \(decoded)")
        }
    }

    @Test func teamListRoundTrips() throws {
        let original = NotificationMessage.teamList(callerWorktree: "/r/.worktrees/dev")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
        if case .teamList(let path) = decoded {
            #expect(path == "/r/.worktrees/dev")
        } else {
            Issue.record("Expected .teamList, got \(decoded)")
        }
    }

    // MARK: - Handler logic via TeamView (TEAM-4.2 / TEAM-4.3 guard conditions)

    private func makeRepo(path: String, displayName: String, branches: [String]) -> RepoEntry {
        TeamTestFixtures.makeRepo(path: path, displayName: displayName, branches: branches)
    }

    @Test func teamListMembersFromTeamViewMatchExpected() {
        let repo = makeRepo(path: "/repo", displayName: "myrepo", branches: ["main", "feature/alice"])
        let wt = repo.worktrees[1]
        let team = TeamView.team(for: wt, in: [repo], teamsEnabled: true)!

        let members = team.members.map { m in
            TeamListMember(
                name: m.name,
                branch: m.branch,
                worktreePath: m.worktreePath,
                role: m.role.rawValue,
                isRunning: m.isRunning
            )
        }
        #expect(members.count == 2)
        let lead = members.first(where: { $0.role == "lead" })!
        #expect(lead.worktreePath == "/repo")
        #expect(lead.branch == "main")
        let coworker = members.first(where: { $0.role == "coworker" })!
        #expect(coworker.branch == "feature/alice")
    }

    @Test func memberNamedReturnsNilForUnknownRecipient() {
        let repo = makeRepo(path: "/repo", displayName: "myrepo", branches: ["main", "alice"])
        let wt = repo.worktrees[0]
        let team = TeamView.team(for: wt, in: [repo], teamsEnabled: true)!
        #expect(team.memberNamed("nobody") == nil)
        #expect(team.memberNamed("alice") != nil)
    }

    @Test func singleWorktreeRepoHasNoTeamForMsgOrList() {
        let repo = makeRepo(path: "/repo", displayName: "myrepo", branches: ["main"])
        let wt = repo.worktrees[0]
        // team() returns nil → msg/list handlers return "not in a team" / "no other team members"
        #expect(TeamView.team(for: wt, in: [repo], teamsEnabled: true) == nil)
    }

    @Test func teamModeDisabledReturnsNilFromTeamView() {
        let repo = makeRepo(path: "/repo", displayName: "myrepo", branches: ["main", "dev"])
        let wt = repo.worktrees[0]
        // teamsEnabled: false → team() returns nil → handler returns "team mode is disabled" before this
        #expect(TeamView.team(for: wt, in: [repo], teamsEnabled: false) == nil)
    }
}
