import Foundation
import GrafttyKit
import GrafttyProtocol

/// Only local creation/status operations enter this handler. A peer cannot
/// supply another remote target or reach the rest of the CLI dispatcher.
@MainActor
enum RemoteCLIWorktreeService {
    static func handle(
        _ request: RemoteWorktreeRequest,
        from device: RemoteDeviceID,
        repos: [RepoEntry],
        status: (String) -> WorktreeCreateStatus?,
        create: (NotificationMessage) -> ResponseMessage,
        readOrigin: GitRepositoryOrigin.Loader? = nil
    ) async -> RemoteTeamResponse {
        let id = request.operationID
        guard !id.isEmpty, id.utf8.count <= 256 else {
            return .error("Invalid remote worktree operation ID")
        }
        // Namespacing prevents one authenticated peer from polling or reusing
        // another peer's operation, including operations submitted locally.
        let scopedID = "remote:\(device.value.utf8.count):\(device.value):\(id)"
        let response: ResponseMessage
        if let retained = status(scopedID) {
            response = .worktreeCreate(retained)
        } else {
            switch request {
            case .status:
                return .error("Unknown or expired remote worktree operation")
            case .create(let options):
                do {
                    let repo = try await options.destinationRepository(in: repos, readOrigin: readOrigin)
                    // Another request can finish origin resolution while this
                    // one is suspended. Recheck before starting the mutation.
                    if let retained = status(scopedID) {
                        response = .worktreeCreate(retained)
                    } else {
                        response = create(.createWorktree(
                            callerWorktree: repo.path, worktreeName: options.worktreeName,
                            branchName: options.branchName, existing: options.existing,
                            base: options.base, command: options.command,
                            agentRuntime: options.agentRuntime, agentPrompt: options.agentPrompt,
                            operationID: scopedID))
                    }
                } catch { return .error(String(describing: error)) }
            }
        }
        switch response {
        case .worktreeCreate(let result):
            return .worktreeCreate(.init(operationID: id, state: result.state,
                worktreePath: result.worktreePath, messageAddress: result.worktreePath, error: result.error))
        case .error(let message): return .error(message)
        default: return .error("Unexpected local worktree creation response")
        }
    }
}
