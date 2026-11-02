import Foundation
import Testing
@testable import GrafttyKit

@MainActor
@Suite("@spec AGENT-6.147: While an agent is the primary agent of a worktree, the application shall keep it available for ongoing work and reserve task-completion instructions and parent cleanup obligations for CLI-added additional agents in existing worktrees.")
struct PrimaryAgentLifecycleTests {
    @Test(arguments: [false, true])
    func launchInstructionsFollowThePersistedRole(primary: Bool) throws {
        var agent = ManagedAgent(name: "Implementation", provider: .codex,
            parent: .init(member: "main", worktree: "/repo", runtime: "codex", agentID: "codex-123456789abc"))
        agent.isPrimary = primary
        agent.launchOrigin = .cliAgentAdd
        let restored = try JSONDecoder().decode(ManagedAgent.self, from: JSONEncoder().encode(agent))
        #expect(restored.isPrimary == primary)
        let prompt = restored.launchPrompt("Implement the feature")
        #expect(prompt.contains("Implement the feature"))
        if primary {
            #expect(prompt.contains("primary agent"))
            #expect(!prompt.contains("graftty agent finish"))
        } else {
            #expect(prompt.contains("graftty agent finish \(agent.id) --assignment \(agent.assignmentID.uuidString)"))
        }
    }

    @Test(arguments: [false, true])
    func addingToExistingWorktreeDistinguishesFirstAndAdditionalAgents(hasPrimary: Bool) async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.controlCapabilities.insert(.paneAgent)
        if hasPrimary {
            var primary = ManagedAgent(name: "Primary", provider: .codex, parent: nil)
            primary.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
            primary.isPrimary = true
            platform.state.repos[0].worktrees[0].agents = [primary]
        }
        let response = await AgentControl.handle(.init(action: .add, callerWorktree: "/repo",
            name: "New agent", worktree: "/repo", provider: .codex), platform: platform)
        guard case .agents(let records) = response else { Issue.record("Expected launch, got \(response)"); return }
        #expect(records.first?.agent.isPrimary == !hasPrimary)
        guard case .addPane(let launch) = platform.platformRequests.first else {
            Issue.record("Expected pane launch"); return
        }
        #expect(launch.managedAgent?.isPrimary == !hasPrimary)
    }

    @Test func delegatedNewWorktreeStillGetsAnOngoingPrimary() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let response = await AgentControl.handle(.init(action: .add, callerWorktree: "/repo",
            callerAgentID: "codex-123456789abc", name: "new-worktree", provider: .codex), platform: platform)
        guard case .agents(let records) = response else { Issue.record("Expected accepted launch, got \(response)"); return }
        #expect(records.first?.agent.isPrimary == true)
        #expect(records.first?.agent.parent?.agentID == "codex-123456789abc")
    }

    @Test func sessionStartRecoversLegacyPrimaryAndAdditionalRoles() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let first = try #require(platform.state.repos[0].worktrees[0].splitTree.allLeaves.first)
        let second = PaneSlotID()
        var worktree = platform.state.repos[0].worktrees[0]
        worktree.splitTree = worktree.splitTree.inserting(second, at: first, direction: .horizontal)
        worktree.ensurePaneSession(for: second)
        var primary = ManagedAgent(name: "Primary", provider: .codex, parent: nil)
        primary.paneSlotID = first
        var additional = ManagedAgent(name: "Reviewer", provider: .codex, parent: nil)
        additional.paneSlotID = second
        worktree.agents = [primary, additional]
        platform.state.repos[0].worktrees[0] = worktree
        // Dictionary iteration does not identify the primary pane in a multi-pane fixture.
        let primarySession = ZmxLauncher.sessionName(for: try #require(worktree.paneSessions[first]))
        let additionalSession = ZmxLauncher.sessionName(for: try #require(worktree.paneSessions[second]))
        let primaryText = try await AgentControl.sessionContext(path: "/repo", agentID: "codex-123456789abc",
            paneSessionName: primarySession, provider: .codex, platform: platform)
        let additionalText = try await AgentControl.sessionContext(path: "/repo", agentID: "codex-abcdef123456",
            paneSessionName: additionalSession, provider: .codex, platform: platform)
        #expect(primaryText.contains("primary agent"))
        #expect(!primaryText.contains("graftty agent finish"))
        #expect(!additionalText.contains("graftty agent finish"))
        #expect(additionalText.contains("Keep this session open"))
        #expect(platform.state.repos[0].worktrees[0].agents.map(\.isPrimary) == [true, false])
        #expect(platform.state.repos[0].worktrees[0].agents.map(\.nativeAgentID)
            == ["codex-123456789abc", "codex-abcdef123456"])
    }

    @Test(arguments: [TeamHookRuntime.codex, .claude])
    func ordinaryTurnRefreshesPrimaryGuidanceWithoutRestart(provider: TeamHookRuntime) async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var primary = ManagedAgent(name: "Primary", provider: provider, parent: nil)
        primary.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        primary.nativeAgentID = "\(provider.rawValue)-123456789abc"
        primary.providerSessionID = "native"
        platform.state.repos[0].worktrees[0].agents = [primary]
        let response = await ControlRequestCore.handleRequest(.teamHook(callerWorktree: "/repo",
            callerAgentID: primary.nativeAgentID, runtime: provider, event: .userPromptSubmit,
            sessionID: "native", paneSessionName: platform.paneSession), platform: platform)
        guard case .teamHookOutput(let json) = response else { Issue.record("Expected hook output"); return }
        #expect(json.contains("primary agent"))
        #expect(!json.contains("graftty agent finish"))
    }

    @Test(arguments: [false, true], [false, true])
    func primaryWorktreeOutlivesItsCreatorButPendingCreationStillBlocksCleanup(creationPending: Bool, interrupted: Bool) async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var parent = ManagedAgent(name: "Creator", provider: .codex, parent: nil)
        parent.launchOrigin = .cliAgentAdd
        parent.isPrimary = false
        parent.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        parent.nativeAgentID = "codex-123456789abc"
        let completion = try parent.finish(assignment: parent.assignmentID, result: "Created the worktree")
        var primary = ManagedAgent(name: "Primary", provider: .codex,
            parent: .init(member: "main", worktree: "/repo", runtime: "codex", agentID: parent.nativeAgentID),
            status: creationPending ? .starting : .running)
        primary.parentManagedAgentID = parent.id
        primary.isPrimary = true
        primary.launchTargetWorktree = "/repo/child"
        if interrupted { primary.sessionEnded(reason: "Provider exited") }
        platform.state.repos[0].worktrees[0].agents = [parent]
        if creationPending {
            platform.state.repos[0].worktrees[0].agents.append(primary)
        } else {
            var childTree = WorktreeEntry(path: "/repo/child", branch: "child", state: .running)
            primary.paneSlotID = childTree.splitTree.allLeaves.first
            childTree.agents = [primary]
            platform.state.repos[0].worktrees.append(childTree)
        }
        let response = await AgentControl.handle(.init(action: .close, callerWorktree: "/repo",
            agentID: parent.id, completionID: completion.id), platform: platform)
        if creationPending && !interrupted {
            #expect(response == .error(AgentControlError.activeChildren.localizedDescription))
            #expect(platform.closedAgentSlots.isEmpty)
        } else {
            guard case .agents = response else { Issue.record("Expected cleanup, got \(response)"); return }
            let retained = try #require(platform.state.repos.flatMap(\.worktrees).flatMap(\.agents).first { $0.id == primary.id })
            #expect(retained.status == (interrupted ? .interrupted : .running))
            #expect(!retained.requiresAcknowledgment)
        }
    }

    @Test func closingLegacyPrimaryDoesNotPromoteAnAdditionalAgentOrReleaseItsCreator() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var original = ManagedAgent(name: "Original primary", provider: .codex, parent: nil)
        original.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        var creator = ManagedAgent(name: "Creator", provider: .codex, parent: nil)
        creator.launchOrigin = .cliAgentAdd
        creator.isPrimary = false
        creator.nativeAgentID = "codex-123456789abc"
        let creatorCompletion = try creator.finish(assignment: creator.assignmentID, result: "Done")
        var additional = ManagedAgent(name: "Additional", provider: .codex,
            parent: .init(member: "creator", worktree: "/repo/creator", runtime: "codex", agentID: creator.nativeAgentID))
        additional.parentManagedAgentID = creator.id
        additional.launchOrigin = .cliAgentAdd
        additional.isPrimary = false
        additional.paneSlotID = PaneSlotID()
        platform.state.repos[0].worktrees[0].agents = [original, additional]
        #expect(!platform.state.repos[0].worktrees[0].isPrimaryAgent(additional))
        original.requestSessionClose(reason: "User ended primary")
        let originalCompletion = try #require(original.completion)
        try original.beginClose(completion: originalCompletion.id)
        original.didClose()
        platform.state.repos[0].worktrees[0].agents[0] = original
        #expect(!platform.state.repos[0].worktrees[0].isPrimaryAgent(additional))
        var creatorTree = WorktreeEntry(path: "/repo/creator", branch: "creator", state: .running)
        creator.paneSlotID = creatorTree.splitTree.allLeaves.first
        creatorTree.agents = [creator]
        platform.state.repos[0].worktrees.append(creatorTree)
        let response = await AgentControl.handle(.init(action: .close, callerWorktree: creatorTree.path,
            agentID: creator.id, completionID: creatorCompletion.id), platform: platform)
        #expect(response == .error(AgentControlError.activeChildren.localizedDescription))
    }

    @Test func turnGuidanceRejectsOtherNativeAgentsAndProviders() throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var primary = ManagedAgent(name: "Primary", provider: .codex, parent: nil)
        primary.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        primary.nativeAgentID = "codex-123456789abc"
        platform.state.repos[0].worktrees[0].agents = [primary]
        #expect(AgentControl.currentSessionInstructions(path: "/repo", agentID: "codex-abcdef123456",
            paneSessionName: platform.paneSession, provider: .codex, platform: platform).isEmpty)
        #expect(AgentControl.currentSessionInstructions(path: "/repo", agentID: primary.nativeAgentID,
            paneSessionName: platform.paneSession, provider: .claude, platform: platform).isEmpty)
        #expect(AgentControl.currentSessionInstructions(path: "/repo", agentID: nil,
            paneSessionName: platform.paneSession, provider: .codex, platform: platform).contains("primary agent"))
    }

    @Test(arguments: [false, true])
    func restartingTheProviderPreservesItsRoleAndBecomesOngoing(primary: Bool) throws {
        var agent = ManagedAgent(name: "Resume", provider: .codex, parent: nil)
        agent.isPrimary = primary
        agent.launchOrigin = .cliAgentAdd
        agent.providerSessionID = "saved-conversation"
        agent.requestSessionClose(reason: "User finished")
        let completion = try #require(agent.completion)
        try agent.beginClose(completion: completion.id)
        agent.didClose()
        try agent.restartConversation()
        #expect(agent.isPrimary == primary)
        #expect(!agent.launchPrompt(nil).contains("graftty agent finish"))
        #expect(agent.launchOrigin == .resumedSession)
    }
}
