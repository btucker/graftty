import Foundation
import Testing
@testable import GrafttyKit

@MainActor
@Suite("@spec AGENT-6.148: When an agent is launched, the application shall enable bounded finish instructions and parent cleanup only for CLI-added additional agents in an existing worktree, preserving ongoing, UI, observed, and unknown-origin sessions.")
struct AgentTerminationScopeTests {
    @Test(arguments: [ManagedAgent.LaunchOrigin.cliAgentAdd, .userInterface, nil], [false, true])
    func existingWorktreeRequiresExplicitCLIOriginAndAnExistingPrimary(origin: ManagedAgent.LaunchOrigin?, hasPrimary: Bool) async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.controlCapabilities.insert(.paneAgent)
        if hasPrimary {
            platform.state.repos[0].worktrees[0].agents = [ManagedAgent(name: "Primary", provider: .codex,
                parent: nil, isPrimary: true)]
        }
        let request = AgentControlRequest(action: .add, callerWorktree: "/repo", name: "Additional",
            worktree: "/repo", provider: .codex, launchOrigin: origin)
        let wire = try JSONDecoder().decode(AgentControlRequest.self, from: JSONEncoder().encode(request))
        let response = await AgentControl.handle(wire, platform: platform)
        guard case .agents(let rows) = response else { Issue.record("Expected launch"); return }
        let agent = try #require(rows.first?.agent)
        let restored = try JSONDecoder().decode(ManagedAgent.self, from: JSONEncoder().encode(agent))
        let eligible = origin == .cliAgentAdd && hasPrimary
        #expect(restored.launchOrigin == origin)
        #expect(restored.isBoundedAssignment == eligible)
        #expect(restored.launchPrompt(nil).contains("graftty agent finish") == eligible)
        guard case .addPane(let launch) = platform.platformRequests.first else { Issue.record("Expected pane launch"); return }
        #expect(launch.managedAgent?.isBoundedAssignment == eligible)
        if eligible {
            var completing = restored
            _ = try completing.finish(assignment: completing.assignmentID, result: "Done")
            #expect(completing.requiresAcknowledgment)
        } else {
            var ongoing = restored
            #expect(throws: ManagedAgent.LifecycleError.ongoingSession) {
                try ongoing.finish(assignment: ongoing.assignmentID, result: "Ready")
            }
        }
    }

    @Test func cliCreatedWorktreeKeepsItsPrimaryOngoing() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let response = await AgentControl.handle(.init(action: .add, callerWorktree: "/repo",
            name: "new-worktree", provider: .codex, launchOrigin: .cliAgentAdd), platform: platform)
        guard case .agents(let rows) = response else { Issue.record("Expected new worktree"); return }
        let agent = try #require(rows.first?.agent)
        #expect(agent.isPrimary == true)
        #expect(!agent.isBoundedAssignment)
        #expect(!agent.launchPrompt(nil).contains("graftty agent finish"))
    }

    @Test(arguments: [ManagedAgent.LaunchOrigin.userInterface, .observedSession, .resumedSession, nil])
    func staleCompletionDoesNotAuthorizeParentCleanup(origin: ManagedAgent.LaunchOrigin?) async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let parentID = "codex-123456789abc"
        var agent = ManagedAgent(name: "Old assignment", provider: .codex,
            parent: .init(member: "main", worktree: "/repo", runtime: "codex", agentID: parentID),
            launchOrigin: .cliAgentAdd, isPrimary: false)
        agent.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        let completion = try agent.finish(assignment: agent.assignmentID, result: "Old completion")
        agent.launchOrigin = origin
        platform.state.repos[0].worktrees[0].agents = [agent]
        await AgentControl.reconcileOutbox(platform: platform)
        #expect(try platform.teamInbox.messages(teamID: "/repo").isEmpty)
        let response = await AgentControl.handle(.init(action: .close, callerWorktree: "/repo",
            callerAgentID: parentID, agentID: agent.id, completionID: completion.id), platform: platform)
        guard case .error = response else { Issue.record("Parent closed an ongoing session"); return }
        #expect(platform.closedAgentSlots.isEmpty)
        let explicitClose = await AgentControl.handle(.init(action: .close, callerWorktree: "/repo",
            agentID: agent.id, completionID: completion.id), platform: platform)
        guard case .agents = explicitClose else { Issue.record("Explicit user close rejected"); return }
        #expect(platform.closedAgentSlots.count == 1)
    }

    @Test func ordinaryAdditionalSessionCannotFinishItsAssignment() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var agent = ManagedAgent(name: "UI agent", provider: .codex,
            parent: .init(member: "main", worktree: "/repo", runtime: "codex", agentID: "codex-123456789abc"))
        agent.isPrimary = false
        agent.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        platform.state.repos[0].worktrees[0].agents = [agent]
        #expect(!agent.launchPrompt(nil).contains("graftty agent finish"))
        let response = await AgentControl.handle(.init(action: .finish, callerWorktree: "/repo",
            paneSessionName: platform.paneSession, agentID: agent.id, assignmentID: agent.assignmentID,
            result: "Ready and waiting"), platform: platform)
        guard case .error = response else { Issue.record("Ongoing session accepted bounded completion"); return }
        #expect(platform.state.repos[0].worktrees[0].agents[0].completion == nil)
        #expect(try platform.teamInbox.messages(teamID: "/repo").isEmpty)
    }

    @Test func observedSecondProviderGetsOngoingInstructions() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let primary = ManagedAgent(name: "Primary", provider: .codex, parent: nil)
        platform.state.repos[0].worktrees[0].agents = [primary]
        let context = try await AgentControl.sessionContext(path: "/repo", agentID: "codex-abcdef123456",
            paneSessionName: platform.paneSession, provider: .codex, platform: platform)
        #expect(!context.contains("graftty agent finish"))
        #expect(context.contains("Keep this session open"))
    }

    @Test func providerExitDoesNotAutomaticallyRemoveOngoingView() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let slot = try #require(platform.state.repos[0].worktrees[0].splitTree.allLeaves.first)
        var agent = ManagedAgent(name: "Ongoing", provider: .codex,
            parent: .init(member: "main", worktree: "/repo", runtime: "codex", agentID: "codex-123456789abc"))
        agent.isPrimary = true
        agent.paneSlotID = slot
        platform.state.repos[0].worktrees[0].agents = [agent]
        platform.liveAgentSessionNames = []
        await AgentControl.reconcileOutbox(platform: platform)
        #expect(platform.closedAgentSlots.isEmpty)
        let retained = platform.state.repos[0].worktrees[0].agents[0]
        #expect(retained.paneSlotID == slot)
        #expect(retained.completion?.outcome != .completed)
        #expect(!retained.requiresAcknowledgment)
        #expect(try platform.teamInbox.messages(teamID: "/repo").isEmpty)
    }
}
