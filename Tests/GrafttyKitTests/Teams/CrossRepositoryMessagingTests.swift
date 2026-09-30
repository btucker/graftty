import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

@Suite("@spec TEAM-4.12: When a sender addresses a tracked local worktree by canonical path with an optional runtime or exact agent suffix, the application shall accept recipients across repositories, store the message in the recipient repository's inbox, preserve the sender's reply identity, and permit replies across repositories, while keeping short member names scoped to the caller's team and rejecting unavailable exact agents without enqueuing.")
struct CrossRepositoryMessagingTests {
    private static func handler(
        inbox: TeamInbox,
        records: [TeamPresenceRecord] = [],
        reachable: Bool = true
    ) -> TeamInboxRequestHandler {
        TeamInboxRequestHandler(
            inbox: inbox,
            dispatcher: TeamEventDispatcher(
                inbox: inbox,
                preferencesProvider: { TeamEventRoutingPreferences() },
                templateProvider: { "" }
            ),
            agentRecords: { records },
            agentReachability: { _ in reachable }
        )
    }

    @Test(arguments: ["", "#claude", "#claude-012345abcdef"])
    func sendsToRecipientInboxAndDelivers(suffix: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamInbox(rootDirectory: root)
        let repos = [
            TeamTestFixtures.makeRepo(path: "/source", displayName: "source", branches: ["main"]),
            TeamTestFixtures.makeRepo(path: "/target", displayName: "target", branches: ["main", "runner"]),
        ]
        let target = "/target/.worktrees/runner"
        let agentID = "claude-012345abcdef"
        let record = TeamPresenceRecord(
            teamID: "/target", worktree: target, runtime: .claude,
            paneSessionName: nil, pid: 101, registeredAt: Date(), runtimeSessionID: "target-session", agentID: agentID
        )
        // Provider addresses must also queue when no agent is registered.
        let sender = Self.handler(inbox: inbox, records: suffix.contains("012345") ? [record] : [])
        let delivery = try sender.send(
            callerWorktree: "/source", callerAgentID: "codex-abcdef012345",
            recipient: target + suffix, text: "cross repository brief", priority: .urgent,
            repos: repos, teamsEnabled: true
        )
        #expect(delivery.recipient.worktreePath == target)
        #expect(delivery.message.team == "target")
        #expect(delivery.message.repoPath == "/target")
        #expect(delivery.message.from.worktree == "/source")
        #expect(delivery.message.from.member == "main")
        #expect(delivery.message.from.agentID == "codex-abcdef012345")
        #expect(delivery.message.to.runtime == (suffix.isEmpty ? nil : "claude"))
        #expect(delivery.message.to.agentID == (suffix.contains("012345") ? agentID : nil))
        #expect(delivery.message.priority == .urgent)
        #expect(try inbox.messages(teamID: "/source").isEmpty)
        #expect(try inbox.worktreePendingMessages(teamID: "/target", recipientWorktree: target).map(\.id) == [delivery.message.id])

        let receiver = Self.handler(inbox: inbox, records: [record])
        let output = try receiver.hook(
            callerWorktree: target, runtime: .claude,
            event: .postToolUse, sessionID: "target-session", paneSessionName: nil,
            repos: repos, teamsEnabled: true, agentID: agentID
        )
        #expect(output.contains("cross repository brief"))
        #expect(try inbox.worktreePendingMessages(teamID: "/target", recipientWorktree: target).isEmpty)
    }

    @Test(arguments: [false, true])
    func repliesPreserveOriginalSenderAcrossRepositories(fallback: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamInbox(rootDirectory: root)
        let repos = [
            TeamTestFixtures.makeRepo(path: "/source", displayName: "source", branches: ["main"]),
            TeamTestFixtures.makeRepo(path: "/target", displayName: "target", branches: ["main"]),
        ]
        let row = try inbox.appendMessage(
            teamID: "/target", teamName: "target", repoPath: "/target",
            from: .init(member: "main", worktree: "/source", runtime: "codex", agentID: "codex-abcdef012345"),
            to: .init(member: "main", worktree: "/target", runtime: nil), priority: .normal, body: "brief"
        )
        let request = try TeamReplyResolver(inbox: inbox).resolve(
            callerWorktree: "/target", callerAgentID: "claude-012345abcdef",
            messageID: row.id, fallback: fallback, text: "received", priority: .normal,
            repos: repos, teamsEnabled: true
        )
        guard case .teamSend(let caller, let agent, let recipient, let text, let priority) = request else {
            Issue.record("Expected a send request")
            return
        }
        #expect(recipient == "/source#\(fallback ? "codex" : "codex-abcdef012345")")
        let record = TeamPresenceRecord(
            teamID: "/source", worktree: "/source", runtime: .codex,
            paneSessionName: nil, pid: 102, registeredAt: Date(), agentID: "codex-abcdef012345"
        )
        let reply = try Self.handler(inbox: inbox, records: [record]).send(
            callerWorktree: caller, callerAgentID: agent, recipient: recipient,
            text: text, priority: priority, repos: repos, teamsEnabled: true
        )
        #expect(reply.message.to.worktree == "/source")
        #expect(reply.message.to.agentID == (fallback ? nil : "codex-abcdef012345"))
        #expect(try inbox.messages(teamID: "/source").map(\.body) == ["received"])
        #expect(try inbox.worktreePendingMessages(teamID: "/target", recipientWorktree: "/target").map(\.id) == [row.id])
    }

    @Test func shortNamesStayLocalAndUnknownAddressesDoNotEnqueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamInbox(rootDirectory: root)
        let repos = [
            TeamTestFixtures.makeRepo(path: "/target", displayName: "target", branches: ["main", "runner", "foreign"]),
            TeamTestFixtures.makeRepo(path: "/source", displayName: "source", branches: ["main", "runner"]),
        ]
        let handler = Self.handler(inbox: inbox)
        let local = try handler.send(
            callerWorktree: "/source", recipient: "runner", text: "local", priority: .normal,
            repos: repos, teamsEnabled: true
        )
        #expect(local.message.to.worktree == "/source/.worktrees/runner")
        for address in ["foreign", "/untracked", "/untracked#claude", "/target#claude-000000000000"] {
            #expect(throws: (any Error).self) {
                try handler.send(
                    callerWorktree: "/source", recipient: address, text: "rejected", priority: .normal,
                    repos: repos, teamsEnabled: true
                )
            }
        }
        #expect(try inbox.messages(teamID: "/target").isEmpty)
        #expect(try inbox.messages(teamID: "/source").count == 1)
    }

    @Test func unreachableExactAgentDoesNotEnqueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamInbox(rootDirectory: root)
        let repos = [
            TeamTestFixtures.makeRepo(path: "/source", displayName: "source", branches: ["main"]),
            TeamTestFixtures.makeRepo(path: "/target", displayName: "target", branches: ["main"]),
        ]
        let id = "claude-012345abcdef"
        let record = TeamPresenceRecord(
            teamID: "/target", worktree: "/target", runtime: .claude,
            paneSessionName: nil, pid: 101, registeredAt: Date(), agentID: id
        )
        let handler = Self.handler(inbox: inbox, records: [record], reachable: false)
        #expect(throws: TeamInboxRequestError.agentUnavailable(id)) {
            try handler.send(
                callerWorktree: "/source", recipient: "/target#\(id)", text: "rejected", priority: .normal,
                repos: repos, teamsEnabled: true
            )
        }
        #expect(try inbox.messages(teamID: "/target").isEmpty)
        #expect(try inbox.messages(teamID: "/source").isEmpty)
    }

    @Test func pathCharactersAndXMLAddressesKeepTheirMeaning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamInbox(rootDirectory: root)
        let repos = [
            TeamTestFixtures.makeRepo(path: "/source", displayName: "source", branches: ["main"]),
            TeamTestFixtures.makeRepo(path: "/target&infra", displayName: "target", branches: ["main", "runner#claude", "R&D#review"]),
        ]
        let handler = Self.handler(inbox: inbox)
        for (address, path, runtime) in [
            ("/target&infra/.worktrees/runner#claude", "/target&infra/.worktrees/runner#claude", nil),
            ("/target&infra/.worktrees/runner#claude#codex", "/target&infra/.worktrees/runner#claude", "codex"),
            ("/target&amp;infra/.worktrees/R&amp;D#review#claude", "/target&infra/.worktrees/R&D#review", "claude"),
        ] {
            let delivery = try handler.send(
                callerWorktree: "/source", recipient: address, text: "brief", priority: .normal,
                repos: repos, teamsEnabled: true
            )
            #expect(delivery.message.to.worktree == path)
            #expect(delivery.message.to.runtime == runtime)
        }
        #expect(try inbox.messages(teamID: "/target&infra").count == 3)
    }

    @Test func ambiguousCrossRepositoryReplyDoesNotResolve() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamInbox(rootDirectory: root)
        let repos = ["/source", "/source#codex", "/target"].map {
            TeamTestFixtures.makeRepo(path: $0, displayName: $0, branches: ["main"])
        }
        let row = try inbox.appendMessage(
            teamID: "/target", teamName: "target", repoPath: "/target",
            from: .init(member: "main", worktree: "/source", runtime: "codex"),
            to: .init(member: "main", worktree: "/target", runtime: nil), priority: .normal, body: "brief"
        )
        #expect(throws: TeamReplyError.ambiguousSender) {
            try TeamReplyResolver(inbox: inbox).resolve(
                callerWorktree: "/target", callerAgentID: nil,
                messageID: row.id, fallback: true, text: "received", priority: .normal,
                repos: repos, teamsEnabled: true
            )
        }
        #expect(try inbox.messages(teamID: "/source").isEmpty)
        #expect(try inbox.messages(teamID: "/source#codex").isEmpty)
    }
}
