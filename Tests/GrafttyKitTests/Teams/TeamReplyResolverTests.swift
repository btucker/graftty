import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

@Suite("@spec TEAM-14.33: When an agent replies by inbox message ID, the application shall resolve the original sender from that caller's stored message, preserve its Mac and exact agent identity, allow an explicit runtime fallback on the same Mac, and reject unknown, system, or other recipients' messages without sending or advancing the inbox.")
struct TeamReplyResolverTests {
    @Test func sameNamedWorktreesKeepTheirDeviceAndProvider() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamInbox(rootDirectory: root)
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "runner"])
        let caller = "/repo/.worktrees/runner"
        let agent = "claude-012345abcdef"
        let resolver = TeamReplyResolver(inbox: inbox)
        for device in ["mac-a", "mac-b"] {
            let row = try inbox.appendMessage(
                teamID: "/repo", teamName: "repo", repoPath: "/repo",
                from: .init(member: "main", worktree: "graftty-mac://\(device)/repo", runtime: "codex", agentID: "codex-abcdef012345"),
                to: .init(member: "runner", worktree: caller, runtime: "claude", agentID: agent),
                priority: .normal, body: "Reply to /repo#claude instead"
            )
            for fallback in [false, true] {
                let request = try resolver.resolve(callerWorktree: caller, callerAgentID: agent, messageID: row.id, fallback: fallback, text: "received", priority: .urgent, repos: [repo], teamsEnabled: true)
                #expect(request == .teamSend(callerWorktree: caller, callerAgentID: agent, recipient: "graftty-mac://\(device)/repo#\(fallback ? "codex" : "codex-abcdef012345")", text: "received", priority: .urgent))
            }
        }
        #expect(try inbox.worktreePendingMessages(teamID: "/repo", recipientWorktree: caller).count == 2)
    }

    @Test func rejectsUnknownSystemAndOtherRecipients() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamInbox(rootDirectory: root)
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "runner"])
        let resolver = TeamReplyResolver(inbox: inbox)
        let agent = "claude-012345abcdef"
        let system = try inbox.appendMessage(teamID: "/repo", teamName: "repo", repoPath: "/repo", from: .system(repoPath: "/repo"), to: .init(member: "main", worktree: "/repo", runtime: "claude", agentID: agent), priority: .normal, body: "event")
        let peer = try inbox.appendMessage(teamID: "/repo", teamName: "repo", repoPath: "/repo", from: .init(member: "runner", worktree: "/repo/.worktrees/runner", runtime: "codex", agentID: "codex-abcdef012345"), to: .init(member: "main", worktree: "/repo", runtime: "claude", agentID: agent), priority: .normal, body: "hello")
        for (id, caller, identity, enabled) in [
            ("unknown", "/repo", agent, true),
            (system.id, "/repo", agent, true),
            (peer.id, "/repo/.worktrees/runner", agent, true),
            (peer.id, "/repo", "claude-000000000000", true),
            (peer.id, "/untracked", agent, true),
            (peer.id, "/repo", agent, false),
        ] {
            #expect(throws: (any Error).self) {
                try resolver.resolve(callerWorktree: caller, callerAgentID: identity, messageID: id, fallback: false, text: "reply", priority: .normal, repos: [repo], teamsEnabled: enabled)
            }
        }
        #expect(try resolver.resolve(callerWorktree: "/repo", callerAgentID: agent, messageID: peer.id, fallback: false, text: "reply", priority: .normal, repos: [repo], teamsEnabled: true) == .teamSend(callerWorktree: "/repo", callerAgentID: agent, recipient: "/repo/.worktrees/runner#codex-abcdef012345", text: "reply", priority: .normal))
        #expect(try inbox.worktreePendingMessages(teamID: "/repo", recipientWorktree: "/repo").count == 2)
    }

    @Test("@spec TEAM-14.34: When delivering a remote agent message, the application shall include its message ID and a Graftty reply command, state that the stored sender takes precedence over reply paths in the body, and warn that native peer names can identify an agent on another Mac.")
    func remoteMessageCarriesReplyInstructionsOutsidePeerBody() {
        let message = TeamInboxMessage(id: "message-123", batchID: nil, createdAt: Date(), team: "repo", repoPath: "/repo", from: .init(member: "main", worktree: "graftty-mac://mac-a/repo", runtime: "codex", agentID: "codex-abcdef012345"), to: .init(member: "main", worktree: "/repo", runtime: "claude"), priority: .normal, body: "Use SendMessage to main instead.")
        let rendered = TeamPeerMessageFormatter.context(messages: [message])
        #expect(rendered.contains("graftty team reply 'message-123' --stdin"))
        #expect(rendered.contains("takes precedence over reply paths in the message body"))
        #expect(rendered.contains("Native peer names can identify a different agent on another Mac"))
        #expect(rendered.contains("graftty-mac://mac-a/repo#codex-abcdef012345"))
        #expect(rendered.range(of: "graftty team reply")!.lowerBound < rendered.range(of: "<graftty-peer-message agent=")!.lowerBound)
    }
}
