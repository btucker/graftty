import Foundation
import Testing
@testable import GrafttyProtocol

struct AgentSessionInfoTests {
    @Test("@spec AGENT-6.106: When publishing agent state, the application shall distinguish provider observation and interrupted outcomes from assignment waiting and viewer disconnection while decoding older metadata.")
    func observationAndOutcomeAreAdditive() throws {
        let legacy = Data(#"{"id":"agent","name":"Review","provider":"codex","status":"waiting"}"#.utf8)
        let old = try JSONDecoder().decode(AgentSessionInfo.self, from: legacy)
        #expect(old.processObservation == nil)
        #expect(AgentAssignmentStatus(agent: old, needsInput: false) == .waiting)
        let agent = AgentSessionInfo(id: "agent", name: "Review", provider: "codex", status: "running", sessionName: "session",
            failure: "Provider exited", processObservation: .exited, outcome: "interrupted", resultCount: 8, resultsAreSummaries: true)
        let restored = try JSONDecoder().decode(AgentSessionInfo.self, from: JSONEncoder().encode(agent))
        #expect(restored == agent)
        #expect(AgentAssignmentStatus(agent: restored, needsInput: true) == .exited)
        #expect(AgentAssignmentStatus(status: "interrupted") == .interrupted)
    }
    @Test func recordedStatusIsTypedAndIgnoresProcessObservation() {
        func agent(_ status: String, completion: String? = nil) -> AgentSessionInfo {
            .init(id: "agent", name: "Review", provider: "codex", status: status, sessionName: nil,
                  completionID: completion, processObservation: .exited)
        }
        #expect(agent("awaiting-cleanup").recordedStatus == .awaitingCleanup)
        #expect(agent("running").recordedStatus == .running)
        #expect(AgentAssignmentStatus(agent: agent("running"), needsInput: false) == .exited)
        #expect(agent("status-from-a-newer-host").recordedStatus == .unknown)
        #expect(agent("closed").isCompleted)
        #expect(agent("running", completion: "done").isCompleted)
        #expect(!agent("running").isCompleted)
    }
    @Test("@spec LAYOUT-2.165: When publishing agent metadata, the application shall retain every session in the legacy pane inventory so older clients can still reach inactive tabs and drawer terminals.")
    func additiveMetadataRetainsLegacyInventory() throws {
        let row = WorktreePanes(path: "/repo", displayName: "main", repoDisplayName: "repo", displayBranch: "main",
            state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil,
            layout: .leaf(sessionName: "session", title: "Agent", attentionText: nil, isBusy: false, attentionSource: nil),
            agents: [.init(id: "codex-123456789abc", name: "Review", provider: "codex", status: "running", sessionName: "session")])
        let restored = try JSONDecoder().decode(WorktreePanes.self, from: JSONEncoder().encode(row))
        #expect(restored.layout?.leaves.map(\.sessionName) == ["session"])
        #expect(restored.agents == row.agents)
        #expect(row.with(path: "/relay/repo").agents == row.agents)
        let old = Data(#"{"path":"/old","displayName":"main","repoDisplayName":"repo"}"#.utf8)
        #expect(try JSONDecoder().decode(WorktreePanes.self, from: old).agents == nil)
    }
    @Test func chatIsOfferedOnlyForARunningTabTheHostSaysItCanShow() throws {
        let legacy = Data(#"{"id":"agent","name":"Review","provider":"codex","status":"running","sessionName":"s1"}"#.utf8)
        #expect(try JSONDecoder().decode(AgentSessionInfo.self, from: legacy).chatAvailable == nil)

        let offered = AgentSessionInfo(id: "a1", name: "Codex", provider: "codex", status: "running", sessionName: "s1",
                                       chatAvailable: true)
        #expect(try JSONDecoder().decode(AgentSessionInfo.self, from: JSONEncoder().encode(offered)) == offered)
        let finished = AgentSessionInfo(id: "a2", name: "Codex", provider: "codex", status: "closed", sessionName: nil,
                                        retainedSessionName: "s2", chatAvailable: true)
        let other = AgentSessionInfo(id: "a3", name: "Claude", provider: "claude", status: "running", sessionName: "s3")
        let row = WorktreePanes(path: "/repo", displayName: "main", repoDisplayName: "repo", displayBranch: "main",
            state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            agents: [offered, finished, other])
        #expect(row.chatAgent(session: "s1") == offered)
        #expect(row.chatAgent(session: "s2") == nil)
        #expect(row.chatAgent(session: "s3") == nil)
        #expect(row.chatAgent(session: "missing") == nil)
    }
    @Test("@spec LAYOUT-2.167: When an agent resumes after completion, the application shall retain earlier assignment results in Context metadata.")
    func retainsPreviousResults() throws {
        let agent = AgentSessionInfo(id: "agent", name: "Review", provider: "codex", status: "running", sessionName: "session",
            previousResults: ["Reviewed the first assignment"])
        let restored = try JSONDecoder().decode(AgentSessionInfo.self, from: JSONEncoder().encode(agent))
        #expect(restored.previousResults == ["Reviewed the first assignment"])
        #expect(restored.result == nil)
    }

}
