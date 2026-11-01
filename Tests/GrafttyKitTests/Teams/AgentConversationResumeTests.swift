import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@MainActor
struct AgentConversationResumeTests {
    @Test("@spec AGENT-6.141: If closing a conversation for resume fails after transcript capture, then the application shall retain the captured archive and the current terminal binding for retry.")
    func failedResumeRetainsTeardownProgress() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.controlCapabilities.insert(.paneAgent)
        var agent = ManagedAgent(name: "Resume", provider: .codex, parent: nil)
        agent.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        agent.providerSessionID = "conversation"
        _ = try agent.finish(assignment: agent.assignmentID, result: "Done")
        platform.state.repos[0].worktrees[0].agents = [agent]
        let archive = AgentTranscriptArchive(id: String(repeating: "b", count: 64), byteCount: 10)
        platform.beforeAgentClose = {
            platform.state.repos[0].worktrees[0].agents[0].transcriptArchive = archive
            platform.state.repos[0].worktrees[0].agents[0].paneSlotID = nil
        }
        platform.agentCloseFailure = "Teardown failed"
        let response = await AgentControl.handle(.init(action: .resume, callerWorktree: "/repo", agentID: agent.id), platform: platform)
        guard case .error = response else { Issue.record("Expected failure"); return }
        let current = platform.state.repos[0].worktrees[0].agents[0]
        #expect(current.transcriptArchive == archive)
        #expect(current.paneSlotID == nil)
        #expect(current.completion == agent.completion)
        #expect(platform.platformRequests.isEmpty)
    }

    @Test("@spec AGENT-6.139: When a paired viewer requests a saved conversation, the host shall return bounded content for the exact worktree and reject an agent addressed through a different worktree.")
    func remoteConversationUsesExactWorktree() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var agent = ManagedAgent(name: "Review", provider: .codex, parent: nil)
        agent.providerSessionID = "conversation"
        _ = try agent.finish(assignment: agent.assignmentID, result: "Done")
        agent.transcript = "Captured transcript"
        platform.state.repos[0].worktrees[0].agents = [agent]
        let response = await AgentControl.conversation(path: "/repo", agentID: agent.id, action: .read, platform: platform)
        guard case .agentConversation(let detail) = response else { Issue.record("Expected conversation detail"); return }
        #expect(detail.result == "Done")
        #expect(detail.transcript == "Captured transcript")
        #expect(detail.canResume)
        let wrongWorktree = await AgentControl.conversation(path: "/other", agentID: agent.id, action: .resume, platform: platform)
        guard case .error = wrongWorktree else { Issue.record("Cross-worktree resume must fail"); return }
        #expect(platform.platformRequests.isEmpty)
    }

    @Test("@spec AGENT-6.135: When a conversation restarts, the application shall retain the previous assignment's transcript archive in history without displaying it as the new assignment's transcript.")
    func restartSeparatesTranscriptGenerations() throws {
        var agent = ManagedAgent(name: "Resume", provider: .claude, parent: nil)
        agent.providerSessionID = "conversation"
        let completion = try agent.finish(assignment: agent.assignmentID, result: "First result")
        let archive = AgentTranscriptArchive(id: String(repeating: "a", count: 64), byteCount: 20)
        agent.transcriptArchive = archive
        try agent.beginClose(completion: completion.id)
        agent.didClose()
        try agent.restartConversation()
        #expect(agent.transcriptArchive == nil)
        #expect(agent.transcriptHistory?[completion.assignmentID] == archive)
        #expect(agent.summary().transcriptHistory == nil)
    }

    @Test("@spec AGENT-6.132: If the host stops after reserving a conversation restart but before binding its terminal, then the application shall recover its completed record and allow another resume attempt.")
    func abandonedRestartReservationIsRetryable() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var agent = ManagedAgent(name: "Resume", provider: .codex, parent: nil)
        agent.providerSessionID = "conversation"
        let completion = try agent.finish(assignment: agent.assignmentID, result: "Retained result")
        try agent.beginClose(completion: completion.id)
        agent.didClose()
        try agent.restartConversation()
        platform.state.repos[0].worktrees[0].agents = [agent]
        await AgentControl.reconcileOutbox(platform: platform)
        let recovered = platform.state.repos[0].worktrees[0].agents[0]
        #expect(recovered.status == .closed)
        #expect(recovered.completion == completion)
        #expect(recovered.results == [completion])
        #expect(recovered.providerSessionID == "conversation")
    }

    @Test("@spec AGENT-6.133: When a completed tab is selected and dismissed, the application shall preserve every live terminal and the durable completion record while targeting the visible tab for commands.")
    func completedPresentationOwnsCommands() throws {
        let a = PaneSlotID(), b = PaneSlotID()
        var agent = ManagedAgent(name: "Complete", provider: .codex, parent: nil)
        agent.paneSlotID = a
        let completion = try agent.finish(assignment: agent.assignmentID, result: "Done")
        try agent.beginClose(completion: completion.id)
        agent.didClose()
        var worktree = WorktreeEntry(path: "/repo", branch: "main", state: .running, splitTree: SplitTree(root: .leaf(b)))
        worktree.agents = [agent]
        var layout = WorkspaceLayout<PaneSlotID>()
        layout.addAgent(a); layout.addAgent(b); layout.select(a)
        worktree.workspaceLayout = layout
        worktree.focusedPaneSlotID = b
        worktree.ensureWorkspaceLayout()
        #expect(worktree.presentationPane == a)
        let dismissed = worktree.dismissCompletedTab(a)
        #expect(dismissed)
        #expect(worktree.presentationPane == b)
        #expect(worktree.splitTree.allLeaves == [b])
        #expect(worktree.agents[0].completion == completion)
        let reopened = worktree.showAgentTab(agent.id)
        #expect(reopened == a)
        #expect(worktree.presentationPane == a)
        #expect(worktree.splitTree.allLeaves == [b])
    }

    @Test("@spec AGENT-6.131: When a cleaned-up conversation restarts, the application shall accept exits only from the new provider launch and retain the previous assignment result.")
    func restartedProviderExitUsesNewGeneration() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var agent = ManagedAgent(name: "Resume", provider: .codex, parent: nil)
        agent.paneSessionID = PaneSessionID()
        agent.providerSessionID = "conversation"
        let prior = try agent.finish(assignment: agent.assignmentID, result: "First result")
        try agent.beginClose(completion: prior.id)
        agent.didClose()
        try agent.restartConversation()
        platform.state.repos[0].worktrees[0].agents = [agent]
        platform.state.repos[0].worktrees[0].paneSessions[try #require(agent.paneSlotID)] = agent.paneSessionID
        let handoff = AgentLifecycleHandoff(directory: platform.agentPromptDirectory.appendingPathComponent("lifecycle"))
        try handoff.publish(.init(agentID: agent.id, assignmentID: prior.assignmentID,
            sessionID: #require(agent.paneSessionID), exitCode: 0))
        await AgentControl.reconcileOutbox(platform: platform)
        #expect(platform.state.repos[0].worktrees[0].agents[0].completion == nil)
        try handoff.publish(.init(agentID: agent.id, assignmentID: agent.assignmentID,
            sessionID: #require(agent.paneSessionID), exitCode: 127))
        await AgentControl.reconcileOutbox(platform: platform)
        let current = platform.state.repos[0].worktrees[0].agents[0]
        #expect(current.status == .failed)
        #expect(current.completion?.assignmentID == agent.assignmentID)
        #expect(current.results.first == prior)
    }

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
