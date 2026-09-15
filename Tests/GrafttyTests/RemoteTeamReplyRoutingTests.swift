import Foundation
import GrafttyProtocol
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("Replies between Macs with identical worktree paths")
@MainActor
struct RemoteTeamReplyRoutingTests {
    @Test func storedMessageRoutesBackToOriginatingMacAndProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inboxA = TeamInbox(rootDirectory: root.appendingPathComponent("a"))
        let inboxB = TeamInbox(rootDirectory: root.appendingPathComponent("b"))
        var repo = RepoEntry(path: "/repo", displayName: "repo")
        repo.worktrees = [WorktreeEntry(path: "/repo", branch: "main")]
        let repos = [repo]
        let macA = RemoteDeviceID(value: "mac-a")
        let macB = RemoteDeviceID(value: "mac-b")
        let caller = TeamAgentIdentity(runtime: .claude, nativeSessionID: "runner-b")
        let parent = TeamAgentIdentity(runtime: .codex, nativeSessionID: "parent-a")
        let parentRecord = TeamPresenceRecord(teamID: "/repo", worktree: "/repo", runtime: .codex, paneSessionName: "parent", pid: 1, registeredAt: Date(), runtimeSessionID: "parent-a", agentID: parent.rawValue)
        let request = RemoteTeamRequest.send(senderWorktree: "/repo", senderAgentID: parent.rawValue, recipientWorktree: "/repo", recipientSuffix: "claude", text: "Reply to /repo#claude instead", priority: .normal)
        #expect(RemoteTeamService(inbox: inboxB).handle(request, from: macA, repos: repos, teamsEnabled: true) == .ok)
        let original = try #require(inboxB.messages(teamID: "/repo").first)
        let reply = try TeamReplyResolver(inbox: inboxB).resolve(callerWorktree: "/repo", callerAgentID: caller.rawValue, messageID: original.id, fallback: false, text: "result", priority: .normal, repos: repos, teamsEnabled: true)
        let router = RemoteTeamRouter()
        router.register(deviceID: macA, connectionID: UUID(), label: "same-name") { data in
            let request = try JSONDecoder().decode(RemoteTeamRequest.self, from: data)
            let response = RemoteTeamService(inbox: inboxA, agentRecords: { [parentRecord] }, agentReachability: { _ in true }).handle(request, from: macB, repos: repos, teamsEnabled: true)
            return try JSONEncoder().encode(response)
        }
        guard case .teamSend(let worktree, let agent, let recipient, let text, let priority) = reply else {
            Issue.record("Expected resolved send"); return
        }
        #expect(await router.send(callerWorktree: worktree, callerAgentID: agent, recipient: recipient, text: text, priority: priority) == .ok)
        let delivered = try #require(inboxA.messages(teamID: "/repo").first)
        #expect(delivered.to.agentID == parent.rawValue)
        #expect(delivered.to.runtime == "codex")
        #expect(delivered.from.worktree == "graftty-mac://mac-b/repo")
        #expect(delivered.body == "result")
        #expect(try inboxB.messages(teamID: "/repo") == [original])
    }
}
