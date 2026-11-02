import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@MainActor
struct ViewerAgentLaunchTests {
    @Test("@spec GIT-5.34: When a worktree is created without an explicit shell command, the application shall launch exactly one primary agent using the selected provider or the owning host's default, with the optional description as its initial message.", arguments: [TeamHookRuntime.codex, .claude], [nil, "Fix the tests.\nKeep $(literal syntax).\n"] as [String?])
    func creationStartsOnePrimaryAgent(provider: TeamHookRuntime, prompt: String?) async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.defaultAgentProvider = provider
        var plans: [CLIWorktreeCreationPlan] = []
        platform.finishCreation = { plan in plans.append(plan); return nil }
        let request = CreateWorktreeRequest(callerWorktree: "/repo", worktreeName: "feature", branchName: "feature",
            existing: false, base: nil, command: nil, agentRuntime: nil, agentPrompt: prompt, operationID: "create-feature")
        let response = await CLIWorktreeCreationRequestHandler.begin(request, platform: platform)
        guard case .worktreeCreate(let status) = response else { Issue.record("Expected creation: \(response)"); return }
        #expect(platform.creationAdmissions == [status.operationID])
        while platform.worktreeCreations.status(operationID: status.operationID)?.state == .pending { await Task.yield() }
        _ = await CLIWorktreeCreationRequestHandler.begin(request, platform: platform)
        let worktree = try #require(platform.state.worktree(forPath: status.worktreePath))
        let agent = try #require(worktree.agents.first)
        #expect(worktree.agents.count == 1)
        #expect(agent.provider == provider)
        #expect(agent.isPrimary == true)
        #expect(agent.initialPrompt == prompt)
        #expect(plans.count == 1)
        #expect(plans.first?.agentRuntime == provider)
        #expect(plans.first?.initialCommand?.contains(agent.id) == true)
    }

    @Test("@spec AGENT-6.149: When a paired viewer adds an agent to a worktree with no panes, the application shall launch the requested provider without changing host selection and reuse that launch when the operation is retried.", arguments: [WorktreeState.closed, .running])
    func emptyWorktreeLaunchIsIdempotent(state: WorktreeState) async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.controlCapabilities.insert(.paneAgent)
        platform.state.repos[0].worktrees[0].state = state
        platform.state.repos[0].worktrees[0].splitTree = SplitTree(root: nil)
        platform.state.repos[0].worktrees[0].paneSessions = [:]
        platform.state.selectedWorktreePath = "/different-worktree"
        let id = UUID()
        let first = await ViewerAgentLaunch.add(path: "/repo", provider: "codex", operationID: id, platform: platform)
        let retry = await ViewerAgentLaunch.add(path: "/repo", provider: "codex", operationID: id, platform: platform)
        #expect(first == retry)
        guard case .created(let path, let pane) = first else { Issue.record("Expected launch: \(first)"); return }
        #expect(path == "/repo")
        let agent = try #require(platform.state.worktree(forPath: path)?.agents.first)
        #expect(pane == agent.paneSessionID.map(ZmxLauncher.sessionName(for:)))
        #expect(agent.provider == .codex)
        #expect(platform.platformRequests.count == 1)
        guard case .addPane(let launch) = platform.platformRequests[0] else { Issue.record("Expected pane launch"); return }
        #expect(launch.selectTab == false)
        #expect(platform.state.selectedWorktreePath == "/different-worktree")
    }

    @Test("Viewer launch validates provider and worktree before creating an agent.")
    func invalidLaunchDoesNotMutateState() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.controlCapabilities.insert(.paneAgent)
        for (path, provider) in [("/missing", "codex"), ("/repo", "shell-command")] {
            let response = await ViewerAgentLaunch.add(path: path, provider: provider, operationID: UUID(), platform: platform)
            guard case .error = response else { Issue.record("Expected error: \(response)"); continue }
        }
        #expect(platform.state.repos[0].worktrees[0].agents.isEmpty)
        #expect(platform.platformRequests.isEmpty)
    }

    @Test("Retrying a failed launch reports its failure instead of an attachable session.")
    func retryOfFailedLaunchRemainsFailure() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.controlCapabilities.insert(.paneAgent)
        let operation = UUID()
        var agent = ManagedAgent(name: "Failed", provider: .codex, parent: nil, status: .starting)
        agent.launchOperationID = operation.uuidString
        agent.paneSessionID = PaneSessionID()
        agent.launchFailed(reason: "Provider startup failed")
        platform.state.repos[0].worktrees[0].agents = [agent]

        let response = await ViewerAgentLaunch.add(path: "/repo", provider: "codex", operationID: operation, platform: platform)

        guard case .error = response else { Issue.record("Expected retained launch failure: \(response)"); return }
        #expect(platform.platformRequests.isEmpty)
        #expect(platform.state.repos[0].worktrees[0].agents.count == 1)
    }

    @Test("Viewer creation resolves the host default before creating the worktree.")
    func missingDefaultDoesNotCreateWorktree() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let response = await ViewerAgentLaunch.create(repository: "/repo", name: "feature", branch: "feature", existingSource: nil,
            platform: platform, configuredProvider: { nil })
        guard case .error(_, let message, _, _) = response else { Issue.record("Expected missing default error"); return }
        #expect(message.contains("default agent"))
        #expect(platform.state.repos[0].worktrees.count == 1)
        #expect(platform.state.repos[0].worktrees[0].agents.isEmpty)
    }
}
