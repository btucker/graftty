import Foundation
import Testing
@testable import GrafttyKit

@MainActor
struct AgentControlTests {
    @Test("@spec AGENT-6.74: When parent cleanup succeeds, the application shall close only the completed child's bound session, retain its result, and make repeated cleanup harmless.")
    func cleanupUsesStableSession() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let slot = try #require(platform.state.repos[0].worktrees[0].splitTree.allLeaves.first)
        let sibling = PaneSlotID()
        platform.state.repos[0].worktrees[0].splitTree = platform.state.repos[0].worktrees[0].splitTree.inserting(sibling, at: slot, direction: .horizontal)
        var child = ManagedAgent(name: "Review", provider: .codex, parent: nil)
        child.paneSlotID = slot
        let completion = try child.finish(assignment: child.assignmentID, result: "Reviewed")
        platform.state.repos[0].worktrees[0].agents = [child]
        let request = NotificationMessage.agent(.init(action: .close, callerWorktree: "/repo", agentID: child.id, completionID: completion.id))
        _ = await ControlRequestCore.handleRequest(request, platform: platform)
        _ = await ControlRequestCore.handleRequest(request, platform: platform)
        #expect(platform.closedAgentSlots == [slot])
        #expect(platform.state.repos[0].worktrees[0].splitTree.allLeaves == [sibling])
        #expect(platform.state.repos[0].worktrees[0].agents[0].status == .closed)
        #expect(platform.state.repos[0].worktrees[0].agents[0].completion?.result == "Reviewed")
    }

    @Test("@spec AGENT-6.75: If agent teardown fails, then the application shall retain the live session and cleanup obligation for a later retry.")
    func failedCloseRemainsPending() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var child = ManagedAgent(name: "Review", provider: .codex, parent: nil)
        child.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        let completion = try child.finish(assignment: child.assignmentID, result: "Reviewed")
        platform.state.repos[0].worktrees[0].agents = [child]
        platform.agentCloseFailure = "Still running"
        _ = await ControlRequestCore.handleRequest(.agent(.init(action: .close, callerWorktree: "/repo", agentID: child.id,
            completionID: completion.id)), platform: platform)
        #expect(platform.state.repos[0].worktrees[0].agents[0].status == .awaitingCleanup)
        #expect(platform.closedAgentSlots.isEmpty)
        #expect(platform.state.repos[0].worktrees[0].splitTree.allLeaves.count == 1)
    }

    @Test("@spec AGENT-6.71: When adding an agent to an explicit worktree, the application shall record the parent and launch identity before creating its terminal and shall reject an unknown worktree without creating another.")
    func addRecordsParentBeforeLaunch() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.controlCapabilities.insert(.paneAgent)
        let response = await ControlRequestCore.handleRequest(.agent(.init(action: .add, callerWorktree: "/repo",
            callerAgentID: "codex-123456789abc", name: "Reviewer", worktree: "/repo", provider: .claude)), platform: platform)
        guard case .agents(let records) = response else { Issue.record("Expected agent launch, got \(String(describing: response))"); return }
        #expect(records.count == 1)
        #expect(records[0].agent.parent?.agentID == "codex-123456789abc")
        #expect(records[0].agent.provider == .claude)
        #expect(platform.state.repos[0].worktrees[0].agents.count == 1)
        let invalid = await ControlRequestCore.handleRequest(.agent(.init(action: .add, callerWorktree: "/repo",
            name: "Other", worktree: "/missing", provider: .codex)), platform: platform)
        guard case .error = invalid else { Issue.record("Expected invalid-worktree error"); return }
        #expect(platform.state.repos[0].worktrees.count == 1)
        #expect(platform.state.repos[0].worktrees[0].agents.count == 1)
    }

    @Test("@spec AGENT-6.69: When a child finishes, the application shall durably notify its exact parent once and retain the cleanup obligation independently of inbox delivery.")
    func finishAndRecover() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let parent = TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: "codex", agentID: "codex-123456789abc")
        var child = ManagedAgent(name: "Review", provider: .claude, parent: parent)
        child.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        platform.state.repos[0].worktrees[0].agents = [child]
        let request = AgentControlRequest(action: .finish, callerWorktree: "/repo", paneSessionName: platform.paneSession,
            agentID: child.id, assignmentID: child.assignmentID, result: "Ready to merge")
        let response = await ControlRequestCore.handleRequest(.agent(request), platform: platform)
        guard case .agents(let records) = response else { Issue.record("Expected agents response: \(String(describing: response))"); return }
        #expect(records.first?.agent.status == .awaitingCleanup)
        let rows = try platform.teamInbox.messages(teamID: "/repo")
        #expect(rows.count == 1)
        #expect(rows.first?.to == parent)
        #expect(rows.first?.body.contains(child.id) == true)
        #expect(rows.first?.body.contains("graftty agent close") == true)
        // Simulate a crash after inbox append but before the outbox receipt save.
        platform.state.repos[0].worktrees[0].agents[0].deliveredCompletionID = nil
        platform.state = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(platform.state))
        _ = await ControlRequestCore.handleRequest(.agent(request), platform: platform)
        #expect(try platform.teamInbox.messages(teamID: "/repo").count == 1)
        #expect(platform.state.repos[0].worktrees[0].agents[0].status == .awaitingCleanup)
    }

    @Test("@spec AGENT-6.70: When an agent requests completion for a different terminal session, the application shall reject it without changing the target assignment.")
    func finishRequiresOwningSession() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var child = ManagedAgent(name: "Review", provider: .codex, parent: nil)
        child.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        platform.state.repos[0].worktrees[0].agents = [child]
        let response = await ControlRequestCore.handleRequest(.agent(.init(action: .finish,
            callerWorktree: "/repo", paneSessionName: "different-session", agentID: child.id,
            assignmentID: child.assignmentID, result: "Wrong child")), platform: platform)
        guard case .error = response else { Issue.record("Expected error"); return }
        #expect(platform.state.repos[0].worktrees[0].agents[0].completion == nil)
    }
    @Test("@spec AGENT-6.76: When a native subagent starts inside a managed terminal, the application shall preserve the top-level agent identity and assignment.")
    func nativeSubagentCannotBindAssignment() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var child = ManagedAgent(name: "Review", provider: .codex, parent: nil)
        child.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        child.nativeAgentID = "codex-123456789abc"
        platform.state.repos[0].worktrees[0].agents = [child]
        let text = try await AgentControl.sessionContext(path: "/repo", agentID: "codex-abcdef123456",
            paneSessionName: platform.paneSession, provider: .codex, isSubagent: true, platform: platform)
        #expect(text.isEmpty)
        #expect(platform.state.repos[0].worktrees[0].agents[0] == child)
    }

    @Test("@spec AGENT-6.77: When a parent resumes in its bound terminal with a new native session identity, the application shall preserve its managed identity and restore its children's cleanup obligations to that session.")
    func parentRestartRestoresCleanup() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let slot = try #require(platform.state.repos[0].worktrees[0].splitTree.allLeaves.first)
        var parent = ManagedAgent(name: "Parent", provider: .codex, parent: nil)
        parent.nativeAgentID = "codex-123456789abc"; parent.paneSlotID = slot
        var child = ManagedAgent(name: "Child", provider: .claude,
            parent: .init(member: "main", worktree: "/repo", runtime: "codex", agentID: parent.nativeAgentID))
        child.parentManagedAgentID = parent.id
        let completion = try child.finish(assignment: child.assignmentID, result: "Done")
        child.deliveredCompletionID = completion.id
        platform.state.repos[0].worktrees[0].agents = [parent, child]
        let context = try await AgentControl.sessionContext(path: "/repo", agentID: "codex-abcdef123456",
            paneSessionName: platform.paneSession, provider: .codex, platform: platform)
        #expect(context.contains("Cleanup pending"))
        #expect(platform.state.repos[0].worktrees[0].agents[0].id == parent.id)
        #expect(platform.state.repos[0].worktrees[0].agents[1].parent?.agentID == "codex-abcdef123456")
        #expect(try platform.teamInbox.messages(teamID: "/repo").first?.to.agentID == "codex-abcdef123456")
    }

}
