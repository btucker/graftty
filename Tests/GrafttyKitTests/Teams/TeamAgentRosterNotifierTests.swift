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

    private func repo() -> RepoEntry {
        RepoEntry(
            path: "/repo",
            displayName: "repo",
            worktrees: [
                WorktreeEntry(path: "/repo", branch: "main"),
                WorktreeEntry(path: "/repo/feature", branch: "feature"),
            ]
        )
    }

    private func presence(
        runtime: TeamHookRuntime,
        sessionID: String,
        registeredAt: TimeInterval,
        isSubagent: Bool = false
    ) -> TeamPresenceRecord {
        TeamPresenceRecord(
            teamID: "/repo",
            worktree: "/repo/feature",
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
