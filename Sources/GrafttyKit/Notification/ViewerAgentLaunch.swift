import Foundation
import GrafttyProtocol

/// Paired viewers use the same managed launch path as native agent controls.
/// Their worktree IDs are resolved by the relay before reaching this service.
@MainActor
public enum ViewerAgentLaunch {
    public static func add(path: String, provider: String?, operationID: UUID,
                           platform: any ControlPlatform) async -> WorktreeManagementResponse {
        guard let worktree = platform.state.worktree(forPath: path) else {
            return failure("This worktree is no longer available.")
        }
        if let provider, TeamHookRuntime(rawValue: provider) == nil {
            return failure("Unknown agent provider.")
        }
        let explicit = provider.flatMap(TeamHookRuntime.init(rawValue:))
        let response = await AgentControl.handle(.init(action: .add, callerWorktree: path,
            name: "Agent \(worktree.agents.count + 1)", worktree: path, provider: explicit,
            operationID: operationID.uuidString, selectTab: false, launchOrigin: .userInterface), platform: platform)
        return result(response)
    }

    public static func create(repository: String, name: String, branch: String,
                              existingSource: RemoteRepositoryInfo.Branch.Source?,
                              agent: WorktreeAgentConfiguration = .init(),
                              platform: any ControlPlatform,
                              configuredProvider: @MainActor () -> TeamHookRuntime? = {
                                  AgentPreference.migrate()
                                  return AgentPreference.provider()
                              }) async -> WorktreeManagementResponse {
        let provider: TeamHookRuntime
        let explicit = agent.provider.flatMap(TeamHookRuntime.init(rawValue:))
        if agent.provider != nil, explicit == nil { return failure("Unknown agent provider.") }
        do { provider = try AgentPreference.resolve(explicit: explicit, configured: configuredProvider()) }
        catch { return failure("Choose a default agent in Agent teams settings on the host, then try again.") }
        guard platform.state.repos.contains(where: { $0.path == repository }) else {
            return failure("This repository is no longer available.")
        }
        let branchSource: BranchSelection.ExistingSource?
        switch existingSource {
        case .local: branchSource = .local
        case .remoteOnly: branchSource = .remoteOnly
        case .automatic:
            do {
                guard let resolved = try await GitExistingBranchSource.resolve(repoPath: repository, branchName: branch) else {
                    return failure("No local or origin branch named \(branch) exists.")
                }
                branchSource = resolved
            } catch { return failure(error.localizedDescription) }
        case nil: branchSource = nil
        }
        let response = await AgentControl.handle(.init(action: .add, callerWorktree: repository,
            name: name, provider: provider, prompt: agent.initialPrompt, operationID: UUID().uuidString, branch: branch,
            existing: existingSource != nil, selectTab: false, existingBranchSource: branchSource,
            launchOrigin: .userInterface), platform: platform)
        guard case .agents(let records) = response, let record = records.first,
              let operation = record.operationID else { return result(response) }
        // Creation continues in its host-owned task if the viewer disconnects.
        // As with shell creation, reply only once the returned pane can attach.
        do {
            while let status = platform.worktreeCreation.worktreeCreationStatus(operationID: operation) {
                switch status.state {
                case .pending: try await Task.sleep(for: .milliseconds(50))
                case .ready: return result(response)
                case .failed: return failure(status.error ?? "Could not start the default agent.")
                }
            }
            return failure("The worktree creation operation is no longer available.")
        } catch { return failure("The request was interrupted; worktree creation may still be running.") }
    }

    private static func result(_ response: ResponseMessage) -> WorktreeManagementResponse {
        if case .error(let message) = response { return failure(message) }
        guard case .agents(let records) = response, let record = records.first,
              let session = record.agent.paneSessionID else { return failure("The agent did not return a session.") }
        if [.failed, .interrupted, .closed].contains(record.agent.status) {
            return failure(record.agent.failure ?? "This agent launch is no longer active.")
        }
        return .created(worktreeID: record.worktree, paneID: ZmxLauncher.sessionName(for: session))
    }

    private static func failure(_ message: String) -> WorktreeManagementResponse {
        .error(code: "agent-launch-failed", message: message, forceAllowed: false, shortStatus: nil)
    }
}
