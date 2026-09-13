import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

@Suite("Remote Mac team messaging")
struct RemoteTeamServiceTests {
    private let peer = RemoteDeviceID(value: "remote-mac-id")

    @Test("@spec TEAM-14.1: When a team address names a remote Mac, the application shall preserve its device ID, absolute worktree path, and optional runtime or canonical agent suffix without path-character collisions.")
    func addressesRoundTrip() throws {
        for path in ["/Users/a/repo", "/Users/a/my repo#claude", "/repo/%2F?&雪"] {
            for suffix in [nil, "claude", "codex-012345abcdef"] {
                let address = try RemoteTeamAddress(deviceID: peer, worktreePath: path, suffix: suffix)
                let parsed = try #require(RemoteTeamAddress(rawValue: address.rawValue))
                #expect(parsed.deviceID == peer)
                #expect(parsed.worktreePath == path)
                #expect(parsed.suffix == suffix)
            }
        }
        #expect(RemoteTeamAddress(rawValue: "graftty-mac://remote-mac-id/dir#display-name") == nil)
        #expect(RemoteTeamAddress(rawValue: "graftty-mac://remote-mac-id") == nil)
        #expect(RemoteTeamAddress(rawValue: "https://remote-mac-id/repo") == nil)
    }

    @Test("@spec TEAM-14.2: When an authenticated remote Mac requests team members, the application shall list tracked local worktrees across repositories, including repositories with one worktree, with repository names and canonical agent addresses.")
    func rosterIncludesSingletonAndCanonicalAgents() throws {
        try withService(records: [presence()]) { service, _ in
            let other = TeamTestFixtures.makeRepo(path: "/other", displayName: "other", branches: ["main"])
            let response = service.handle(.list, from: peer, repos: [repo(), other], teamsEnabled: true)
            guard case .members(let members) = response else { Issue.record("Expected members"); return }
            #expect(members.map(\.worktreePath) == ["/repo", "/other"])
            #expect(members.map(\.name) == ["repo/main", "other/main"])
            #expect(members[0].agents.first?.address == "/repo#\(agentID)")
        }
    }

    @Test("@spec TEAM-14.3: While team mode is disabled, the application shall reject remote team listing and messages without writing an inbox row.")
    func disabledTeamsRejectRequests() throws {
        try withService { (service, inbox) throws in
            #expect(service.handle(.list, from: peer, repos: [repo()], teamsEnabled: false).isError)
            #expect(service.handle(request(), from: peer, repos: [repo()], teamsEnabled: false).isError)
            #expect(try inbox.messages(teamID: "/repo").isEmpty)
        }
    }

    @Test("@spec TEAM-14.4: When an authenticated remote Mac sends a team message, the application shall durably append it to the local recipient inbox and qualify the sender worktree with the authenticated device ID.")
    func senderIsQualifiedAndMessageIsDurable() throws {
        try withService { (service, inbox) throws in
            #expect(service.handle(request(senderAgentID: agentID), from: peer, repos: [repo()], teamsEnabled: true) == .ok)
            let row = try #require(inbox.messages(teamID: "/repo").first)
            #expect(row.from.worktree == "graftty-mac://remote-mac-id/sender")
            #expect(row.from.runtime == "claude")
            #expect(row.from.agentID == agentID)
            #expect(row.to.worktree == "/repo")
            #expect(row.body == "hello")
            #expect(row.priority == .urgent)
            #expect(try inbox.worktreePendingMessages(teamID: "/repo", recipientWorktree: "/repo") == [row])
            let rendered = TeamHookRenderer.format(messages: [row])
            #expect(rendered.contains("agent=\"graftty-mac://remote-mac-id/sender#\(agentID)\""))
            #expect(rendered.contains("fallback-agent=\"graftty-mac://remote-mac-id/sender#claude\""))
        }
    }

    @Test("@spec TEAM-14.5: When a remote team message names a recipient, the application shall require an exact tracked local worktree path and reject branch names, child paths, and unknown worktrees.")
    func recipientsMustMatchTrackedPaths() throws {
        try withService { (service, inbox) throws in
            for recipient in ["main", "/repo/child", "/unknown", "/repo#friendly-agent"] {
                #expect(service.handle(request(recipient: recipient), from: peer, repos: [repo()], teamsEnabled: true).isError)
            }
            #expect(try inbox.messages(teamID: "/repo").isEmpty)
        }
    }

    @Test("@spec TEAM-14.6: When a remote team message targets a canonical agent ID, the application shall bind delivery to that exact reachable agent and reject missing or stale agents without enqueuing.")
    func exactAgentsFailClosed() throws {
        try withService(records: [presence()]) { (service, inbox) throws in
            #expect(service.handle(request(recipient: "/repo#\(agentID)"), from: peer, repos: [repo()], teamsEnabled: true) == .ok)
            #expect(try inbox.messages(teamID: "/repo").first?.to.agentID == agentID)
            #expect(service.handle(request(recipient: "/repo#codex-000000000000"), from: peer, repos: [repo()], teamsEnabled: true).isError)
            #expect(try inbox.messages(teamID: "/repo").count == 1)
        }
        try withService(records: [presence()], reachable: false) { (service, inbox) throws in
            #expect(service.handle(request(recipient: "/repo#\(agentID)"), from: peer, repos: [repo()], teamsEnabled: true).isError)
            #expect(try inbox.messages(teamID: "/repo").isEmpty)
        }
    }

    @Test("@spec TEAM-14.7: When a remote team message targets a runtime, the application shall retain the runtime without pinning an agent so it can wait for that provider's next session.")
    func runtimeAddressQueuesWithoutAgent() throws {
        try withService { (service, inbox) throws in
            #expect(service.handle(request(recipient: "/repo#codex"), from: peer, repos: [repo()], teamsEnabled: true) == .ok)
            let row = try #require(inbox.messages(teamID: "/repo").first)
            #expect(row.to.runtime == "codex")
            #expect(row.to.agentID == nil)
        }
    }

    @Test("@spec TEAM-14.8: If a remote team message has an invalid sender path, invalid sender agent ID, or blank body, then the application shall reject it without enqueuing.")
    func invalidMessagesDoNotWrite() throws {
        try withService { (service, inbox) throws in
            for invalid in [request(senderWorktree: "relative"), request(senderWorktree: "graftty-mac://spoof/repo"), request(senderAgentID: "friendly-agent"), request(text: " \n\t")] {
                #expect(service.handle(invalid, from: peer, repos: [repo()], teamsEnabled: true).isError)
            }
            #expect(try inbox.messages(teamID: "/repo").isEmpty)
        }
    }

    @Test("@spec TEAM-14.9: When exchanging remote team requests and responses, the application shall preserve message priority, agent identities, and member records through encoding and decoding.")
    func wireValuesRoundTrip() throws {
        let message = request(senderAgentID: agentID)
        #expect(try JSONDecoder().decode(RemoteTeamRequest.self, from: JSONEncoder().encode(message)) == message)
        let response = RemoteTeamResponse.members([TeamListMember(name: "repo/main", branch: "main", worktreePath: "/repo", isMainWorktree: true, isRunning: false)])
        #expect(try JSONDecoder().decode(RemoteTeamResponse.self, from: JSONEncoder().encode(response)) == response)
    }

    @Test("Literal runtime-looking path suffixes remain distinct from runtime recipients.")
    func pathSuffixCollisionDoesNotChangeRecipient() throws {
        try withService { (service, inbox) throws in
            var tracked = repo()
            tracked.worktrees.append(WorktreeEntry(path: "/repo#claude", branch: "other"))
            for (path, suffix) in [("/repo#claude", nil), ("/repo", "claude")] {
                let address = try RemoteTeamAddress(deviceID: peer, worktreePath: path, suffix: suffix)
                let decoded = try #require(RemoteTeamAddress(rawValue: address.rawValue))
                let request = RemoteTeamRequest.send(senderWorktree: "/sender#codex", senderAgentID: nil, recipientWorktree: decoded.worktreePath, recipientSuffix: decoded.suffix, text: "hello", priority: .normal)
                #expect(service.handle(request, from: peer, repos: [tracked], teamsEnabled: true) == .ok)
            }
            let rows = try inbox.messages(teamID: "/repo")
            #expect(rows.map(\.to.worktree) == ["/repo#claude", "/repo"])
            #expect(rows.map(\.to.runtime) == [nil, "claude"])
            #expect(rows.allSatisfy { $0.from.worktree == "graftty-mac://remote-mac-id/sender%23codex" })
        }
    }

    @Test("A singleton repository delivers remote messages through the existing session hook and acknowledges them.")
    func singletonHookConsumesRemoteMessage() throws {
        try withService { (service, inbox) throws in
            #expect(service.handle(request(), from: peer, repos: [repo()], teamsEnabled: true) == .ok)
            let handler = TeamInboxRequestHandler(
                inbox: inbox,
                dispatcher: TeamEventDispatcher(inbox: inbox, preferencesProvider: { TeamEventRoutingPreferences() }, templateProvider: { "" })
            )
            let output = try handler.hook(callerWorktree: "/repo", runtime: .claude, event: .sessionStart, sessionID: "session", paneSessionName: "pane", repos: [repo()], teamsEnabled: true)
            let payload = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: [String: String]])
            let context = try #require(payload["hookSpecificOutput"]?["additionalContext"])
            #expect(context.contains("graftty-mac://remote-mac-id/sender"))
            #expect(context.contains("hello"))
            #expect(try inbox.worktreePendingMessages(teamID: "/repo", recipientWorktree: "/repo").isEmpty)
        }
    }

    private var agentID: String { TeamAgentIdentity(runtime: .claude, nativeSessionID: "session").rawValue }
    private func repo() -> RepoEntry { TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main"]) }
    private func presence() -> TeamPresenceRecord {
        TeamPresenceRecord(teamID: "/repo", worktree: "/repo", runtime: .claude, paneSessionName: "pane", pid: 1, registeredAt: Date(), runtimeSessionID: "session")
    }
    private func request(senderWorktree: String = "/sender", senderAgentID: String? = nil, recipient: String = "/repo", text: String = "hello") -> RemoteTeamRequest {
        let parts = recipient.split(separator: "#", maxSplits: 1).map(String.init)
        return .send(senderWorktree: senderWorktree, senderAgentID: senderAgentID, recipientWorktree: parts[0], recipientSuffix: parts.count > 1 ? parts[1] : nil, text: text, priority: .urgent)
    }
    private func withService(records: [TeamPresenceRecord] = [], reachable: Bool = true, body: (RemoteTeamService, TeamInbox) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = TeamInbox(rootDirectory: directory)
        try body(RemoteTeamService(inbox: inbox, agentRecords: { records }, agentReachability: { _ in reachable }), inbox)
    }
}

private extension RemoteTeamResponse {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}
