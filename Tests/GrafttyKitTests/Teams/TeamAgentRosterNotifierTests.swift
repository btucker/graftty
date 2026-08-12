import Foundation
import Testing
@testable import GrafttyKit

@Suite("Native team-agent roster notifications")
struct TeamAgentRosterNotifierTests {
    @Test("""
    @spec AGENT-6.12: When a top-level agent becomes reachable in a worktree, the application shall notify every reachable top-level agent in that worktree at its exact canonical address with the joined agents and current worktree roster; repeated observations and native subagents shall not create duplicate notifications.
    """)
    func joinNotifiesExactCurrentRosterOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-roster-\(UUID().uuidString)")
        let inbox = TeamInbox(rootDirectory: root, idGenerator: incrementingIDs())
        let initial = presence(runtime: .claude, sessionID: "claude-1", registeredAt: 1)
        let notifier = TeamAgentRosterNotifier(
            inbox: inbox,
            initialRecords: [initial],
            isReachable: { _ in true }
        )
        let codex = presence(runtime: .codex, sessionID: "codex-2", registeredAt: 2)
        let repos = [repo()]

        try await notifier.reconcile(records: [initial, codex], repos: repos)

        let messages = try inbox.messages(teamID: "/repo")
        let claudeID = TeamAgentIdentity(runtime: .claude, nativeSessionID: "claude-1").rawValue
        let codexID = TeamAgentIdentity(runtime: .codex, nativeSessionID: "codex-2").rawValue
        #expect(messages.count == 2)
        #expect(Set(messages.compactMap(\.to.agentID)) == [claudeID, codexID])
        #expect(messages.allSatisfy { $0.kind == "team_agent_joined" })
        #expect(messages.allSatisfy { $0.to.worktree == "/repo/feature" })
        #expect(messages.allSatisfy { $0.body.contains("/repo/feature#\(codexID)") })
        #expect(messages.allSatisfy { $0.body.contains("/repo/feature#\(claudeID)") })

        try await notifier.reconcile(records: [initial, codex], repos: repos)
        #expect(try inbox.messages(teamID: "/repo").count == 2)

        let subagent = presence(
            runtime: .claude,
            sessionID: "native-child",
            registeredAt: 3,
            isSubagent: true
        )
        try await notifier.reconcile(records: [initial, codex, subagent], repos: repos)
        #expect(try inbox.messages(teamID: "/repo").count == 2)
    }

    @Test("The first agent after an empty startup receives its own initial roster.")
    func firstAgentReceivesRoster() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-roster-first-\(UUID().uuidString)")
        let inbox = TeamInbox(rootDirectory: root, idGenerator: incrementingIDs())
        let notifier = TeamAgentRosterNotifier(
            inbox: inbox,
            initialRecords: [],
            isReachable: { _ in true }
        )
        let first = presence(runtime: .claude, sessionID: "first", registeredAt: 1)

        try await notifier.reconcile(records: [first], repos: [repo()])

        let message = try #require(inbox.messages(teamID: "/repo").first)
        #expect(message.to.agentID == TeamAgentIdentity(
            runtime: .claude,
            nativeSessionID: "first"
        ).rawValue)
    }

    @Test("A transient reachability dip does not re-announce agents that never left.")
    func transientDipDoesNotDuplicateJoins() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-roster-dip-\(UUID().uuidString)")
        let inbox = TeamInbox(rootDirectory: root, idGenerator: incrementingIDs())
        let notifier = TeamAgentRosterNotifier(
            inbox: inbox,
            initialRecords: [],
            isReachable: { _ in true }
        )
        let first = presence(runtime: .claude, sessionID: "first", registeredAt: 1)
        let repos = [repo()]

        try await notifier.reconcile(records: [first], repos: repos)
        #expect(try inbox.messages(teamID: "/repo").count == 1)

        // A presence-read hiccup (or momentary socket/pane flap) surfaces as
        // an empty snapshot; the agent never actually left.
        try await notifier.reconcile(records: [], repos: repos)
        try await notifier.reconcile(records: [first], repos: repos)
        #expect(try inbox.messages(teamID: "/repo").count == 1)
    }

    @Test("A join observed before repos resolve is announced on a later pass.")
    func joinBeforeReposResolveIsAnnouncedLater() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-roster-late-\(UUID().uuidString)")
        let inbox = TeamInbox(rootDirectory: root, idGenerator: incrementingIDs())
        let notifier = TeamAgentRosterNotifier(
            inbox: inbox,
            initialRecords: [],
            isReachable: { _ in true }
        )
        let first = presence(runtime: .claude, sessionID: "first", registeredAt: 1)

        try await notifier.reconcile(records: [first], repos: [])
        #expect(try inbox.messages(teamID: "/repo").isEmpty)

        try await notifier.reconcile(records: [first], repos: [repo()])
        #expect(try inbox.messages(teamID: "/repo").count == 1)
    }

    @Test("""
    @spec AGENT-6.22: If appending a join announcement fails partway through a worktree's recipients, then the application shall still advance that worktree's observed roster so already-committed announcements are never re-appended on a later reconciliation, and shall continue announcing the remaining worktrees in the same pass.
    """)
    func partialAppendFailureNeitherDuplicatesNorBlocksOtherWorktrees() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-roster-partial-\(UUID().uuidString)")
        let underlying = TeamInbox(rootDirectory: root, idGenerator: incrementingIDs())
        let codexID = TeamAgentIdentity(runtime: .codex, nativeSessionID: "codex-2").rawValue
        let inbox = RecipientFailingInbox(wrapping: underlying, failingAgentID: codexID)
        let notifier = TeamAgentRosterNotifier(
            appendingTo: inbox,
            initialRecords: [],
            isReachable: { _ in true }
        )
        let claude = presence(runtime: .claude, sessionID: "claude-1", registeredAt: 1)
        let codex = presence(runtime: .codex, sessionID: "codex-2", registeredAt: 2)
        let other = presence(
            runtime: .claude,
            sessionID: "other-1",
            registeredAt: 3,
            worktree: "/repo/other"
        )
        let repos = [repo()]

        // claude-1's row commits, then codex-2's append fails partway
        // through the feature worktree; the other worktree must still be
        // announced in this same pass.
        try await notifier.reconcile(records: [claude, codex, other], repos: repos)

        let claudeID = TeamAgentIdentity(runtime: .claude, nativeSessionID: "claude-1").rawValue
        let otherID = TeamAgentIdentity(runtime: .claude, nativeSessionID: "other-1").rawValue
        let firstPass = try underlying.messages(teamID: "/repo")
        #expect(firstPass.filter { $0.to.agentID == claudeID }.count == 1)
        #expect(firstPass.filter { $0.to.agentID == otherID }.count == 1)

        // The next tick must not re-announce rows that may already have
        // landed in a live session.
        try await notifier.reconcile(records: [claude, codex, other], repos: repos)

        let secondPass = try underlying.messages(teamID: "/repo")
        #expect(secondPass.filter { $0.to.agentID == claudeID }.count == 1)
        #expect(secondPass.count == firstPass.count)
    }

    private struct StubAppendFailure: Error {}

    /// Wraps a real inbox but fails every append addressed to one agent,
    /// simulating an I/O failure partway through a scope's recipients.
    private final class RecipientFailingInbox: TeamRosterAnnouncementAppending {
        private let underlying: TeamInbox
        private let failingAgentID: String

        init(wrapping underlying: TeamInbox, failingAgentID: String) {
            self.underlying = underlying
            self.failingAgentID = failingAgentID
        }

        func appendMessage(
            teamID: String,
            teamName: String,
            repoPath: String,
            from: TeamInboxEndpoint,
            to: TeamInboxEndpoint,
            priority: TeamInboxPriority,
            kind: String,
            body: String,
            agentPrompt: String?,
            source: String?
        ) throws -> TeamInboxMessage {
            guard to.agentID != failingAgentID else { throw StubAppendFailure() }
            return try underlying.appendMessage(
                teamID: teamID,
                teamName: teamName,
                repoPath: repoPath,
                from: from,
                to: to,
                priority: priority,
                kind: kind,
                body: body,
                agentPrompt: agentPrompt,
                source: source
            )
        }
    }

    private func repo() -> RepoEntry {
        RepoEntry(
            path: "/repo",
            displayName: "repo",
            worktrees: [
                WorktreeEntry(path: "/repo", branch: "main"),
                WorktreeEntry(path: "/repo/feature", branch: "feature"),
                WorktreeEntry(path: "/repo/other", branch: "other"),
            ]
        )
    }

    private func presence(
        runtime: TeamHookRuntime,
        sessionID: String,
        registeredAt: TimeInterval,
        isSubagent: Bool = false,
        worktree: String = "/repo/feature"
    ) -> TeamPresenceRecord {
        TeamPresenceRecord(
            teamID: "/repo",
            worktree: worktree,
            runtime: runtime,
            paneSessionName: "pane-\(sessionID)",
            pid: 100,
            registeredAt: Date(timeIntervalSince1970: registeredAt),
            runtimeSessionID: sessionID,
            isSubagent: isSubagent
        )
    }

    private func incrementingIDs() -> () -> String {
        let state = IDState()
        return { state.next() }
    }

    private final class IDState: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return "message-\(value)"
        }
    }
}
