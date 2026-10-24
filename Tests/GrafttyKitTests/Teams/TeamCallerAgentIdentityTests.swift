import Foundation
import Testing
@testable import GrafttyKit

@Suite("Team caller identity ownership")
struct TeamCallerAgentIdentityTests {
    private func record(
        worktree: String = "/repo",
        runtime: TeamHookRuntime = .codex,
        pane: String? = "parent-pane",
        session: String = "parent",
        agentID: String? = nil,
        registeredAt: TimeInterval = 10,
        isSubagent: Bool = false
    ) -> TeamPresenceRecord {
        TeamPresenceRecord(
            teamID: "/repo", worktree: worktree, runtime: runtime,
            paneSessionName: pane, pid: 101,
            registeredAt: Date(timeIntervalSince1970: registeredAt),
            runtimeSessionID: session, agentID: agentID, isSubagent: isSubagent
        )
    }

    @Test("@spec TEAM-4.15: When a team CLI caller inherits an agent ID from another worktree or pane, the application shall use only reachable top-level presence in the caller's worktree and pane to identify the sender, accepting the inherited ID only when it belongs to that presence and leaving ambiguous identity unset.", arguments: [false, true])
    func claudeSendDoesNotInheritParentCodexIdentity(hasCodexImplementer: Bool) throws {
        let child = "/repo/.worktrees/child"
        let parent = record()
        let claude = record(worktree: child, runtime: .claude, pane: "child-pane", session: "child", registeredAt: 20)
        let parentID = TeamAgentDirectory.identity(for: parent).rawValue
        let claudeID = TeamAgentDirectory.identity(for: claude).rawValue
        let implementer = record(worktree: child, pane: "implementer-pane", session: "implementer")
        let records = hasCodexImplementer ? [parent, implementer, claude] : [parent, claude]
        let repos = [TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "child"])]
        let callerID = AttentionReportIdentity.currentAgentID(
            worktreePath: child,
            environment: ["GRAFTTY_AGENT_ID": parentID, "ZMX_SESSION": "child-pane"],
            records: records, isReachable: { _ in true }
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-caller-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamInbox(rootDirectory: root)
        let handler = TeamInboxRequestHandler(
            inbox: inbox,
            dispatcher: TeamEventDispatcher(
                inbox: inbox,
                preferencesProvider: { TeamEventRoutingPreferences() },
                templateProvider: { "" }
            ),
            agentRecords: { records }, agentReachability: { _ in true }
        )
        let delivery = try handler.send(
            callerWorktree: child, callerAgentID: callerID,
            recipient: "/repo", text: "child result", priority: .normal,
            repos: repos
        )
        #expect(delivery.message.from.worktree == child)
        #expect(delivery.message.from.runtime == "claude")
        #expect(delivery.message.from.agentID == claudeID)
        let reply = try TeamReplyResolver(inbox: inbox).resolve(
            callerWorktree: "/repo", callerAgentID: parentID,
            messageID: delivery.message.id, fallback: false,
            text: "review received", priority: .normal,
            repos: repos
        )
        #expect(reply.recipient == "\(child)#\(claudeID)")
    }

    @Test("An inherited ID from another pane cannot select the sender.")
    func otherPaneIdentityIsIgnored() {
        let other = record()
        let current = record(runtime: .claude, pane: "current-pane", session: "current")
        #expect(TeamCallerAgentIdentityResolver.resolve(
            explicitAgentID: TeamAgentDirectory.identity(for: other).rawValue,
            worktree: "/repo", paneSessionName: "current-pane", records: [other, current],
            isReachable: { _ in true }
        ) == TeamAgentDirectory.identity(for: current).rawValue)
    }

    @Test("An explicit ID can disambiguate live agents in the same pane.", arguments: [TeamHookRuntime.codex, .claude], [false, true])
    func ownedExplicitIdentityIsPreserved(_ runtime: TeamHookRuntime, paneLess: Bool) {
        let pane = paneLess ? nil : "parent-pane"
        let first = record(runtime: runtime, pane: pane)
        let second = record(runtime: runtime, pane: pane, session: "second", agentID: "\(runtime.rawValue)-012345abcdef")
        let id = TeamAgentDirectory.identity(for: second).rawValue
        #expect(TeamCallerAgentIdentityResolver.resolve(
            explicitAgentID: id, worktree: "/repo", paneSessionName: pane,
            records: [first, second], isReachable: { _ in true }
        ) == id)
        var environment = ["GRAFTTY_AGENT_ID": id]
        environment["ZMX_SESSION"] = pane
        #expect(AttentionReportIdentity.currentAgentID(
            worktreePath: "/repo",
            environment: environment,
            records: [first, second], isReachable: { _ in true }
        ) == id)
    }

    @Test("Unknown, unreachable, and subagent IDs cannot establish caller identity.", arguments: ["missing", "unreachable", "subagent", "ambiguous"])
    func unownedExplicitIdentityIsNotTrusted(_ scenario: String) {
        let first = record(isSubagent: scenario == "subagent")
        let id = TeamAgentDirectory.identity(for: first).rawValue
        let records: [TeamPresenceRecord] = switch scenario {
        case "missing": []
        case "ambiguous": [record(session: "second"), record(session: "third")]
        default: [first]
        }
        #expect(TeamCallerAgentIdentityResolver.resolve(
            explicitAgentID: id, worktree: "/repo", paneSessionName: "parent-pane",
            records: records, isReachable: { _ in scenario != "unreachable" }
        ) == nil)
    }

    @Test("Without pane evidence, an explicit ID cannot borrow a named pane's identity.")
    func missingPaneDoesNotTrustEnvironmentIdentity() {
        let presence = record()
        #expect(AttentionReportIdentity.currentAgentID(
            worktreePath: "/repo",
            environment: ["GRAFTTY_AGENT_ID": TeamAgentDirectory.identity(for: presence).rawValue],
            records: [presence], isReachable: { _ in true }
        ) == nil)
    }
}
