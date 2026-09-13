import Foundation
import GrafttyProtocol
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("Remote team routing")
@MainActor
struct RemoteTeamRouterTests {
    @Test("@spec TEAM-14.32: When a team member query specifies a repository or worktree, the application shall preserve that scope and fetch remote members only for unscoped roster queries.")
    func scopedMembersStayLocal() async throws {
        let router = RemoteTeamRouter()
        let local = ResponseMessage.teamList(teamName: "local", members: [])
        router.register(deviceID: RemoteDeviceID(value: "studio"), connectionID: UUID(), label: "Studio") { _ in
            try JSONEncoder().encode(RemoteTeamResponse.members([
                TeamListMember(name: "remote/main", branch: "main", worktreePath: "/remote", isMainWorktree: true, isRunning: true)
            ]))
        }
        for request in [
            NotificationMessage.teamMembers(callerWorktree: "/local", worktree: nil, repo: "/local"),
            .teamMembers(callerWorktree: "/local", worktree: "/local", repo: nil)
        ] {
            #expect(await router.includingRemoteMembers(in: local, for: request) == local)
        }
        for request in [
            NotificationMessage.teamList(callerWorktree: "/local"),
            .teamMembers(callerWorktree: "/local", worktree: nil, repo: nil)
        ] {
            let response = await router.includingRemoteMembers(in: local, for: request)
            guard case .teamList(_, let members) = response else { Issue.record("Expected roster"); continue }
            #expect(members.count == 1)
        }
    }

    @Test("@spec TEAM-14.10: When a connected Mac publishes team members, the application shall qualify their worktree and agent addresses with that Mac's device identity.")
    func qualifiesRoster() async throws {
        let router = RemoteTeamRouter()
        let device = RemoteDeviceID(value: "studio")
        let agent = TeamListAgent(id: "codex-123456abcdef", address: "/repo#codex-123456abcdef", runtime: .codex, displayName: nil, isReachable: true, paneSessionName: nil)
        router.register(deviceID: device, connectionID: UUID(), label: "Studio") { _ in
            try JSONEncoder().encode(RemoteTeamResponse.members([
                TeamListMember(name: "repo/main", branch: "main", worktreePath: "/repo", isMainWorktree: true, isRunning: true, agents: [agent])
            ]))
        }
        let members = await router.members()
        let member = try #require(members.first)
        #expect(RemoteTeamAddress(rawValue: member.worktreePath)?.deviceID == device)
        #expect(RemoteTeamAddress(rawValue: member.agents[0].address)?.worktreePath == "/repo")
        #expect(RemoteTeamAddress(rawValue: member.agents[0].address)?.suffix == agent.id)
        #expect(member.name.contains("Studio"))
    }

    @Test("@spec TEAM-14.11: When an agent sends to a remote address, the application shall route only to that connected device and return its inbox acknowledgement.")
    func routesExactDevice() async throws {
        let router = RemoteTeamRouter()
        let device = RemoteDeviceID(value: "studio")
        let recipient = try RemoteTeamAddress(deviceID: device, worktreePath: "/repo", suffix: "claude").rawValue
        router.register(deviceID: device, connectionID: UUID(), label: "Studio") { data in
            let request = try JSONDecoder().decode(RemoteTeamRequest.self, from: data)
            guard case .send(let sender, let agent, let target, let suffix, let text, let priority) = request else {
                Issue.record("Expected directed send")
                return try JSONEncoder().encode(RemoteTeamResponse.error("wrong request"))
            }
            #expect(sender == "/local")
            #expect(agent == "codex-123456abcdef")
            #expect(target == "/repo")
            #expect(suffix == "claude")
            #expect(text == "hello")
            #expect(priority == .urgent)
            return try JSONEncoder().encode(RemoteTeamResponse.ok)
        }
        let result = await router.send(callerWorktree: "/local", callerAgentID: "codex-123456abcdef", recipient: recipient, text: "hello", priority: .urgent)
        #expect(result == .ok)
    }

    @Test("@spec TEAM-14.12: If a remote Mac is disconnected, then the application shall reject directed team sends without falling back to a local worktree.")
    func disconnectedFailsClosed() async throws {
        let router = RemoteTeamRouter()
        let address = try RemoteTeamAddress(deviceID: RemoteDeviceID(value: "gone"), worktreePath: "/repo").rawValue
        let result = await router.send(callerWorktree: "/repo", callerAgentID: nil, recipient: address, text: "hello", priority: .normal)
        guard case .error = result else { Issue.record("Disconnected send succeeded"); return }
    }

    @Test("@spec TEAM-14.13: When a replaced team connection closes, the application shall preserve the newer connection to that Mac.")
    func staleDisconnectPreservesReplacement() async throws {
        let router = RemoteTeamRouter()
        let device = RemoteDeviceID(value: "studio")
        let old = UUID()
        let new = UUID()
        router.register(deviceID: device, connectionID: old, label: "Studio") { _ in throw URLError(.notConnectedToInternet) }
        router.register(deviceID: device, connectionID: new, label: "Studio") { _ in try JSONEncoder().encode(RemoteTeamResponse.ok) }
        router.unregister(deviceID: device, connectionID: old)
        let address = try RemoteTeamAddress(deviceID: device, worktreePath: "/repo").rawValue
        #expect(await router.send(callerWorktree: "/local", callerAgentID: nil, recipient: address, text: "hello", priority: .normal) == .ok)
        router.unregister(deviceID: device, connectionID: new)
        guard case .error = await router.send(callerWorktree: "/local", callerAgentID: nil, recipient: address, text: "hello", priority: .normal) else {
            Issue.record("Closed route survived"); return
        }
    }
}
