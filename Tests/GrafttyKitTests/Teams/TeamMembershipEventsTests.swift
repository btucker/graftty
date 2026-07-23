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

    @Test func joiningAddsRoutedEventForMainWorktree() throws {
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
        // Main worktree is the repo root.
        #expect(messages.first?.to.worktree == "/r/multi")
    }

    @Test func joinDoesNotFireWhenJoinerIsMainWorktree() throws {
        let root = try Self.temporaryDirectory()
        let (dispatcher, inbox) = Self.makeDispatcher(rootDirectory: root)
        let repo = makeRepo(branches: ["main"])  // main worktree would be alone

        TeamMembershipEvents.fireJoined(
            repo: repo,
            joinerWorktreePath: "/r/multi",  // the main worktree
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

    @Test func leaveFiresEventForMainWorktree() throws {
        let root = try Self.temporaryDirectory()
        let (dispatcher, inbox) = Self.makeDispatcher(rootDirectory: root)
        // Repo state after removal: main worktree remains; leaver is already gone.
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

    @Test func leaveDoesNotFireIfMainWorktreeIsGone() throws {
        let root = try Self.temporaryDirectory()
        let (dispatcher, inbox) = Self.makeDispatcher(rootDirectory: root)
        // Main-worktree removal edge case: if it is gone too, nobody to notify.
        // Repo state after removal: empty worktrees array.
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
