import Testing
import Foundation
@testable import GrafttyKit

@Suite("Team membership events")
struct TeamMembershipEventsTests {

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("teamMembershipEventsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeDispatcher(rootDirectory: URL) -> (TeamEventDispatcher, TeamInbox) {
        let inbox = TeamInbox(rootDirectory: rootDirectory)
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "" }
        )
        return (dispatcher, inbox)
    }

    private func makeRepo(branches: [String]) -> RepoEntry {
        TeamTestFixtures.makeRepo(branches: branches)
    }

    @Test func joiningAddsRoutedEventForLead() throws {
        let root = try Self.temporaryDirectory()
        let (dispatcher, inbox) = Self.makeDispatcher(rootDirectory: root)
        let repo = makeRepo(branches: ["main", "feature/login"])

        TeamMembershipEvents.fireJoined(
            repo: repo,
            joinerWorktreePath: "/r/multi/.worktrees/feature-login",
            teamsEnabled: true,
            dispatcher: dispatcher
        )

        let messages = try inbox.messages(teamID: TeamLookup.id(forRepoPath: repo.path))
        #expect(messages.count == 1)
        #expect(messages.first?.kind == TeamChannelEvents.EventType.memberJoined)
        // Lead is the root worktree.
        #expect(messages.first?.to.worktree == "/r/multi")
    }

    @Test func joinDoesNotFireWhenJoinerIsTheLead() throws {
        let root = try Self.temporaryDirectory()
        let (dispatcher, inbox) = Self.makeDispatcher(rootDirectory: root)
        let repo = makeRepo(branches: ["main"])  // single-worktree → lead would be alone

        TeamMembershipEvents.fireJoined(
            repo: repo,
            joinerWorktreePath: "/r/multi",  // the root worktree (lead)
            teamsEnabled: true,
            dispatcher: dispatcher
        )

        let messages = try inbox.messages(teamID: TeamLookup.id(forRepoPath: repo.path))
        #expect(messages.isEmpty)
    }

    @Test func joinDoesNotFireWhenTeamModeOff() throws {
        let root = try Self.temporaryDirectory()
        let (dispatcher, inbox) = Self.makeDispatcher(rootDirectory: root)
        let repo = makeRepo(branches: ["main", "feature/login"])

        TeamMembershipEvents.fireJoined(
            repo: repo,
            joinerWorktreePath: "/r/multi/.worktrees/feature-login",
            teamsEnabled: false,
            dispatcher: dispatcher
        )

        let messages = try inbox.messages(teamID: TeamLookup.id(forRepoPath: repo.path))
        #expect(messages.isEmpty)
    }

    @Test func leaveFiresEventForLead() throws {
        let root = try Self.temporaryDirectory()
        let (dispatcher, inbox) = Self.makeDispatcher(rootDirectory: root)
        // Repo state AFTER removal — lead remains, leaver is gone but we know its branch+path
        let repo = makeRepo(branches: ["main"])

        TeamMembershipEvents.fireLeft(
            repo: repo,
            leaverBranch: "feature/login",
            leaverPath: "/r/multi/.worktrees/feature-login",
            reason: .removed,
            teamsEnabled: true,
            dispatcher: dispatcher
        )

        let messages = try inbox.messages(teamID: TeamLookup.id(forRepoPath: repo.path))
        #expect(messages.count == 1)
        #expect(messages.first?.kind == TeamChannelEvents.EventType.memberLeft)
        #expect(messages.first?.to.worktree == "/r/multi")
    }

    @Test func leaveDoesNotFireWhenTeamModeOff() throws {
        let root = try Self.temporaryDirectory()
        let (dispatcher, inbox) = Self.makeDispatcher(rootDirectory: root)
        let repo = makeRepo(branches: ["main"])

        TeamMembershipEvents.fireLeft(
            repo: repo,
            leaverBranch: "feature/login",
            leaverPath: "/r/multi/.worktrees/feature-login",
            reason: .removed,
            teamsEnabled: false,
            dispatcher: dispatcher
        )

        let messages = try inbox.messages(teamID: TeamLookup.id(forRepoPath: repo.path))
        #expect(messages.isEmpty)
    }

    @Test func leaveDoesNotFireIfLeadGone() throws {
        let root = try Self.temporaryDirectory()
        let (dispatcher, inbox) = Self.makeDispatcher(rootDirectory: root)
        // Lead-removal edge case: if the lead is gone too, nobody to notify.
        // Repo state after removal: empty worktrees array (lead was removed).
        let repo = RepoEntry(path: "/r/multi", displayName: "multi-repo")

        TeamMembershipEvents.fireLeft(
            repo: repo,
            leaverBranch: "main",
            leaverPath: "/r/multi",
            reason: .removed,
            teamsEnabled: true,
            dispatcher: dispatcher
        )

        let messages = try inbox.messages(teamID: TeamLookup.id(forRepoPath: repo.path))
        #expect(messages.isEmpty)
    }

    @Test("@spec TEAM-2.5: TeamMembershipEvents.fireJoined writes a team_member_joined inbox row through the dispatcher.")
    func fireJoinedRoutesThroughDispatcher() throws {
        let root = try Self.temporaryDirectory()
        let (dispatcher, inbox) = Self.makeDispatcher(rootDirectory: root)
        let repo = TeamTestFixtures.makeRepo(
            path: "/repo",
            displayName: "repo",
            branches: ["main", "alice"]
        )

        TeamMembershipEvents.fireJoined(
            repo: repo,
            joinerWorktreePath: "/repo/.worktrees/alice",
            teamsEnabled: true,
            dispatcher: dispatcher
        )

        let messages = try inbox.messages(teamID: TeamLookup.id(forRepoPath: "/repo"))
        #expect(messages.count == 1)
        let msg = try #require(messages.first)
        #expect(msg.kind == TeamChannelEvents.EventType.memberJoined)
        #expect(msg.to.worktree == "/repo")
        #expect(msg.from.member == "system")
    }
}
