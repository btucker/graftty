import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@MainActor
struct AgentConversationResumeTests {
    @Test("@spec AGENT-6.124: When a user resumes a cleaned-up agent, the application shall reserve a new assignment and terminal binding for its exact saved provider conversation while retaining its tab identity and prior results.")
    func restartClosedConversation() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.controlCapabilities.insert(.paneAgent)
        let slot = try #require(platform.state.repos[0].worktrees[0].splitTree.allLeaves.first)
        var agent = ManagedAgent(name: "Review", provider: .codex, parent: nil)
        agent.paneSlotID = slot
        agent.paneSessionID = platform.state.repos[0].worktrees[0].paneSessions[slot]
        agent.providerSessionID = "provider-conversation-123"
        let completion = try agent.finish(assignment: agent.assignmentID, result: "First result")
        try agent.beginClose(completion: completion.id)
        agent.didClose()
        platform.state.repos[0].worktrees[0].agents = [agent]
        platform.state.repos[0].worktrees[0].paneSessions = [:]
        platform.state.repos[0].worktrees[0].splitTree = SplitTree(root: nil)
        let response = await AgentControl.handle(.init(action: .resume, callerWorktree: "/repo", agentID: agent.id), platform: platform)
        guard case .agents(let records) = response else { Issue.record("Expected resume: \(response)"); return }
        let restarted = try #require(records.first?.agent)
        #expect(restarted.assignmentID != agent.assignmentID)
        #expect(restarted.status == .starting)
        #expect(restarted.presentationSlotID == slot)
        #expect(restarted.resumingSessionID == "provider-conversation-123")
        #expect(platform.state.repos[0].worktrees[0].agents[0].results == [completion])
        #expect(restarted.retainedResultCount == 1)
        #expect(restarted.completion == nil)
        #expect(platform.platformRequests.count == 1)
        platform.state.repos[0].worktrees[0].paneSessions[slot] = restarted.paneSessionID
        let duplicate = await AgentControl.handle(.init(action: .resume, callerWorktree: "/repo", agentID: agent.id), platform: platform)
        guard case .error = duplicate else { Issue.record("Starting twice must be rejected"); return }
        #expect(platform.platformRequests.count == 1)
    }

    @Test("@spec AGENT-6.125: When a managed terminal closes, the application shall retain its tab group, selection, and conversation slot independently of the live pane inventory.")
    func closingPreservesTabAndSelection() throws {
        let slot = PaneSlotID(), sibling = PaneSlotID()
        var agent = ManagedAgent(name: "Review", provider: .claude, parent: nil)
        agent.paneSlotID = slot
        var tree = WorktreeEntry(path: "/repo", branch: "main", state: .running)
        tree.splitTree = SplitTree(root: .leaf(slot)).inserting(sibling, at: slot, direction: .horizontal)
        tree.agents = [agent]
        tree.ensureWorkspaceLayout()
        let before = try #require(tree.workspaceLayout)
        let completion = try tree.agents[0].finish(assignment: agent.assignmentID, result: "Done")
        try tree.agents[0].beginClose(completion: completion.id)
        tree.agents[0].didClose()
        tree.splitTree = SplitTree(root: .leaf(sibling))
        tree.ensureWorkspaceLayout()
        #expect(tree.workspaceLayout?.groups == before.groups)
        #expect(tree.workspaceLayout?.root == before.root)
        #expect(tree.agents[0].presentationSlotID == slot)
    }

    @Test("@spec AGENT-6.126: When a provider session starts, the application shall retain its exact conversation ID separately from its Graftty routing identity for later resume.", arguments: [TeamHookRuntime.claude, .codex])
    func hookRetainsConversationID(provider: TeamHookRuntime) async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let response = await ControlRequestCore.handleRequest(.teamHook(callerWorktree: "/repo", callerAgentID: "\(provider.rawValue)-123456789abc", runtime: provider,
            event: .sessionStart, sessionID: "exact-conversation", paneSessionName: platform.paneSession), platform: platform)
        #expect(response != nil)
        #expect(platform.state.repos[0].worktrees[0].agents.first?.providerSessionID == "exact-conversation")
    }
}
