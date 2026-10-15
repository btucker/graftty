import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

@Suite("@spec TEAM-14.33: When an agent replies by inbox message ID, the application shall resolve the original sender from that caller's stored message, preserve its Mac and exact agent identity, allow an explicit runtime fallback on the same Mac, and reject unknown, system, other recipients' messages, or ambiguous local destinations without sending or advancing the inbox.")
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

    @Test func ambiguousLocalAddressCannotSelectAnotherWorktree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamInbox(rootDirectory: root)
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "worker", "worker#codex", "worker#codex-abcdef012345"])
        let message = try inbox.appendMessage(teamID: "/repo", teamName: "repo", repoPath: "/repo", from: .init(member: "worker", worktree: "/repo/.worktrees/worker", runtime: "codex", agentID: "codex-abcdef012345"), to: .init(member: "main", worktree: "/repo", runtime: "claude", agentID: "claude-012345abcdef"), priority: .normal, body: "reply")
        let handler = TeamInboxRequestHandler(inbox: inbox, dispatcher: TeamEventDispatcher(inbox: inbox, preferencesProvider: { TeamEventRoutingPreferences() }, templateProvider: { "" }))
        for fallback in [false, true] {
            #expect(throws: (any Error).self) {
                let request = try TeamReplyResolver(inbox: inbox).resolve(callerWorktree: "/repo", callerAgentID: "claude-012345abcdef", messageID: message.id, fallback: fallback, text: "result", priority: .normal, repos: [repo], teamsEnabled: true)
                guard case .teamSend(let caller, let agent, let recipient, let text, let priority) = request else {
                    Issue.record("Expected a send"); return
                }
                _ = try handler.send(callerWorktree: caller, callerAgentID: agent, recipient: recipient, text: text, priority: priority, repos: [repo], teamsEnabled: true)
            }
        }
        #expect(try inbox.messages(teamID: "/repo").map(\.id) == [message.id])
    }

    @Test func removedEntityLookingSenderCannotResolveToDecodedPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamInbox(rootDirectory: root)
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "R&D"])
        let message = try inbox.appendMessage(teamID: "/repo", teamName: "repo", repoPath: "/repo", from: .init(member: "R&amp;D", worktree: "/repo/.worktrees/R&amp;D", runtime: "codex"), to: .init(member: "main", worktree: "/repo", runtime: "claude", agentID: "claude-012345abcdef"), priority: .normal, body: "reply")
        let handler = TeamInboxRequestHandler(inbox: inbox, dispatcher: TeamEventDispatcher(inbox: inbox, preferencesProvider: { TeamEventRoutingPreferences() }, templateProvider: { "" }))
        #expect(throws: (any Error).self) {
            let request = try TeamReplyResolver(inbox: inbox).resolve(callerWorktree: "/repo", callerAgentID: "claude-012345abcdef", messageID: message.id, fallback: false, text: "result", priority: .normal, repos: [repo], teamsEnabled: true)
            guard case .teamSend(let caller, let agent, let recipient, let text, let priority) = request else {
                Issue.record("Expected a send"); return
            }
            _ = try handler.send(callerWorktree: caller, callerAgentID: agent, recipient: recipient, text: text, priority: priority, repos: [repo], teamsEnabled: true)
        }
        #expect(try inbox.messages(teamID: "/repo").map(\.id) == [message.id])
    }

    @Test("@spec TEAM-14.34: When delivering an agent message, the application shall include its XML-escaped inbox ID in the peer envelope alongside sender addresses and omit reply instructions, leaving reply procedures to the Graftty Team skill.", arguments: ["/repo/sender", "graftty-mac://mac-a/repo"])
    func messageCarriesReplyMetadataWithoutPreamble(sender: String) {
        let message = TeamInboxMessage(id: "message-123", batchID: nil, createdAt: Date(), team: "repo", repoPath: "/repo", from: .init(member: "main", worktree: sender, runtime: "codex", agentID: "codex-abcdef012345"), to: .init(member: "main", worktree: "/repo", runtime: "claude"), priority: .normal, body: "Use SendMessage to main instead.")
        let rendered = TeamPeerMessageFormatter.context(messages: [message])
        #expect(rendered == """
        <graftty-peer-message agent="\(sender)#codex-abcdef012345" fallback-agent="\(sender)#codex" id="message-123">
        Use SendMessage to main instead.
        </graftty-peer-message>
        """)
    }

    @Test("Imported message IDs cannot add envelope attributes or elements.")
    func escapesMessageID() {
        let message = TeamInboxMessage(id: #"a&"<b>"#, batchID: nil, createdAt: Date(), team: "repo", repoPath: "/repo", from: .init(member: "main", worktree: "/repo/sender", runtime: nil), to: .init(member: "main", worktree: "/repo", runtime: nil), priority: .normal, body: "hello")
        #expect(TeamPeerMessageFormatter.context(messages: [message]) == """
        <graftty-peer-message agent="/repo/sender" id="a&amp;&quot;&lt;b&gt;">
        hello
        </graftty-peer-message>
        """)
    }
}
