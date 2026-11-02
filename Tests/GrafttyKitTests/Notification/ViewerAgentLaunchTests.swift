import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@MainActor
struct ViewerAgentLaunchTests {
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
