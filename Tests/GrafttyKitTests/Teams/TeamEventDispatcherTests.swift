import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamEventDispatcher")
struct TeamEventDispatcherTests {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("teamEventDispatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("@spec TEAM-5.1: When team_message is dispatched, the application shall append exactly one inbox row addressed to the named recipient.")
    func teamMessageWritesOneRowToRecipient() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root)
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "" }
        )

        try dispatcher.dispatchTeamMessage(
            fromWorktree: "/repo/.worktrees/alice",
            to: "main",
            text: "ping",
            priority: .normal,
            repos: [repo],
            teamsEnabled: true
        )

        let team = TeamLookup.team(for: "/repo/.worktrees/alice", in: [repo])!
        let messages = try inbox.messages(teamID: TeamLookup.id(of: team))
        #expect(messages.count == 1)
        #expect(messages.first?.from.member == "alice")
        #expect(messages.first?.to.member == "main")
        #expect(messages.first?.body == "ping")
        #expect(messages.first?.kind == "team_message")
    }

    @Test("@spec TEAM-5.5: When PRStatusStore fires pr_state_changed (non-merged), the dispatcher shall write one inbox row per recipient resolved via the prStateChanged matrix row.")
    func prStateChangedFansOutPerMatrix() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice", "bob"])
        let inbox = TeamInbox(rootDirectory: root)
        let prefs = TeamEventRoutingPreferences(
            prStateChanged: [.worktree, .otherWorktrees],
            prMerged: [.root],
            ciConclusionChanged: [.worktree],
            mergabilityChanged: [.worktree]
        )
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { prefs },
            templateProvider: { "" }
        )

        let event = ChannelServerMessage.event(
            type: TeamChannelEvents.WireType.prStateChanged,
            attrs: ["worktree": "/repo/.worktrees/alice", "to": "open", "from": "draft", "pr_number": "42", "pr_url": "https://x", "provider": "github", "repo": "x/y"],
            body: "PR #42 state changed: draft → open"
        )

        try dispatcher.dispatchRoutableEvent(
            event,
            subjectWorktreePath: "/repo/.worktrees/alice",
            repos: [repo]
        )

        let team = TeamLookup.team(for: "/repo/.worktrees/alice", in: [repo])!
        let messages = try inbox.messages(teamID: TeamLookup.id(of: team))
        #expect(messages.count == 2)
        let recipientPaths = Set(messages.map { $0.to.worktree })
        #expect(recipientPaths == ["/repo/.worktrees/alice", "/repo/.worktrees/bob"])
        #expect(messages.allSatisfy { $0.kind == "pr_state_changed" })
        #expect(messages.allSatisfy { $0.from.member == "system" })
    }

    @Test("@spec TEAM-5.9: When pr_state_changed fires in a single-worktree repo, the dispatcher shall write the row to the subject worktree iff .worktree is in the matrix row.")
    func prStateChangedSingleWorktreeRepo() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main"])
        let inbox = TeamInbox(rootDirectory: root)
        let prefs = TeamEventRoutingPreferences(
            prStateChanged: [.worktree],
            prMerged: [.root],
            ciConclusionChanged: [.worktree],
            mergabilityChanged: [.worktree]
        )
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { prefs },
            templateProvider: { "" }
        )

        let event = ChannelServerMessage.event(
            type: TeamChannelEvents.WireType.prStateChanged,
            attrs: ["worktree": "/repo", "to": "open", "from": "draft", "pr_number": "42", "pr_url": "https://x", "provider": "github", "repo": "x/y"],
            body: "PR #42"
        )

        try dispatcher.dispatchRoutableEvent(event, subjectWorktreePath: "/repo", repos: [repo])

        let messages = try inbox.messages(teamID: TeamLookup.id(forRepoPath: "/repo"))
        #expect(messages.count == 1)
        #expect(messages.first?.to.worktree == "/repo")
    }

    @Test("@spec TEAM-5.6: When pr_state_changed has attrs.to == 'merged', the dispatcher shall use the prMerged matrix row.")
    func prMergedUsesMergedRow() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root)
        let prefs = TeamEventRoutingPreferences(
            prStateChanged: [],
            prMerged: [.root],
            ciConclusionChanged: [],
            mergabilityChanged: []
        )
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { prefs },
            templateProvider: { "" }
        )

        let event = ChannelServerMessage.event(
            type: TeamChannelEvents.WireType.prStateChanged,
            attrs: ["worktree": "/repo/.worktrees/alice", "to": "merged", "from": "open", "pr_number": "42", "pr_url": "https://x", "provider": "github", "repo": "x/y"],
            body: "PR #42 state changed: open → merged"
        )

        try dispatcher.dispatchRoutableEvent(
            event,
            subjectWorktreePath: "/repo/.worktrees/alice",
            repos: [repo]
        )

        let team = TeamLookup.team(for: "/repo/.worktrees/alice", in: [repo])!
        let messages = try inbox.messages(teamID: TeamLookup.id(of: team))
        #expect(messages.count == 1)
        #expect(messages.first?.to.worktree == "/repo")
    }

    @Test("@spec TEAM-5.7: When a worktree joins a team-enabled repo, the dispatcher shall append one team_member_joined inbox row addressed to the lead.")
    func memberJoinedAddressesLead() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root)
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "" }
        )

        try dispatcher.dispatchMemberJoined(
            joinerWorktreePath: "/repo/.worktrees/alice",
            repos: [repo]
        )

        let team = TeamLookup.team(for: "/repo", in: [repo])!
        let messages = try inbox.messages(teamID: TeamLookup.id(of: team))
        #expect(messages.count == 1)
        #expect(messages.first?.to.worktree == "/repo")
        #expect(messages.first?.kind == "team_member_joined")
        #expect(messages.first?.from.member == "system")
    }

    @Test("@spec TEAM-5.10: When team_message is dispatched and the user's teamPrompt template is non-empty, the dispatcher shall write the inbox row with the original event body and the rendered per-recipient prompt stored separately as agentPrompt.")
    func teamMessageRespectsTeamPromptTemplate() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root)
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "From {{ agent.branch }}:" }
        )

        let message = try dispatcher.dispatchTeamMessage(
            fromWorktree: "/repo",
            to: "alice",
            text: "ping",
            priority: .normal,
            repos: [repo],
            teamsEnabled: true
        )

        let resolved = try #require(message)
        // Recipient is alice, so `agent.branch == "alice"`. The original
        // event body is stored verbatim; the rendered prompt is split out
        // into agentPrompt with the body auto-appended.
        #expect(resolved.body == "ping")
        #expect(resolved.agentPrompt?.contains("From alice:") == true)
        #expect(resolved.agentPrompt?.contains("ping") == true)
    }

    @Test("@spec TEAM-5.12: When a routable event is dispatched and the user's teamPrompt template is non-empty, the dispatcher shall write the inbox row with the original event body intact and the rendered per-recipient prompt stored separately as agentPrompt.")
    func routableEventStoresBodyAndAgentPromptSeparately() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root)
        let prefs = TeamEventRoutingPreferences(
            prStateChanged: [.worktree],
            prMerged: [.root],
            ciConclusionChanged: [.worktree],
            mergabilityChanged: [.worktree]
        )
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { prefs },
            templateProvider: { "Hello {{ agent.branch }}." }
        )

        let body = "PR #42 state changed: draft → open"
        let event = ChannelServerMessage.event(
            type: TeamChannelEvents.WireType.prStateChanged,
            attrs: ["worktree": "/repo/.worktrees/alice", "to": "open", "from": "draft", "pr_number": "42", "pr_url": "https://x", "provider": "github", "repo": "x/y"],
            body: body
        )

        try dispatcher.dispatchRoutableEvent(
            event,
            subjectWorktreePath: "/repo/.worktrees/alice",
            repos: [repo]
        )

        let team = TeamLookup.team(for: "/repo/.worktrees/alice", in: [repo])!
        let messages = try inbox.messages(teamID: TeamLookup.id(of: team))
        #expect(messages.count == 1)
        let row = try #require(messages.first)
        // Body field carries the original event body — no prelude, no
        // agent prompt mixed in.
        #expect(row.body == body)
        // Rendered prompt is split out into agentPrompt. The template
        // includes `{{ agent.branch }}` (proves the template ran) and
        // the auto-append wires the body in too.
        #expect(row.agentPrompt?.contains("Hello alice.") == true)
        #expect(row.agentPrompt?.contains(body) == true)
    }

    @Test("@spec TEAM-5.11: When team_broadcast is dispatched, the dispatcher shall write one team_message inbox row per non-sender team member, each rendered against that recipient's agent context.")
    func teamBroadcastFansOutPerRecipient() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice", "bob"])
        let inbox = TeamInbox(rootDirectory: root)
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "" }
        )

        let messages = try dispatcher.dispatchTeamBroadcast(
            fromWorktree: "/repo/.worktrees/alice",
            text: "heads up",
            priority: .urgent,
            repos: [repo],
            teamsEnabled: true
        )

        #expect(messages.count == 2)
        let recipients = Set(messages.map(\.to.member))
        #expect(recipients == ["main", "bob"])
        #expect(messages.allSatisfy { $0.from.member == "alice" })
        #expect(messages.allSatisfy { $0.kind == "team_message" })
        #expect(messages.allSatisfy { $0.body == "heads up" })
    }

    @Test("@spec TEAM-5.8: When a worktree is removed from a team-enabled repo (collapsing to one worktree), the dispatcher shall still append one team_member_left inbox row addressed to the lead.")
    func memberLeftAddressesLeadEvenWhenTeamShrinks() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main"])  // alice is gone
        let inbox = TeamInbox(rootDirectory: root)
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "" }
        )

        try dispatcher.dispatchMemberLeft(
            leaverBranch: "alice",
            leaverWorktreePath: "/repo/.worktrees/alice",
            reason: .removed,
            repos: [repo]
        )

        let teamID = TeamLookup.id(forRepoPath: "/repo")
        let messages = try inbox.messages(teamID: teamID)
        #expect(messages.count == 1)
        #expect(messages.first?.to.worktree == "/repo")
        #expect(messages.first?.kind == "team_member_left")
    }
}
