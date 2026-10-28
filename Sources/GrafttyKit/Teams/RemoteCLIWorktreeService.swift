import Foundation
import GrafttyProtocol

/// Only local creation/status operations enter this handler. A peer cannot
/// supply another remote target or reach the rest of the CLI dispatcher.
@MainActor
public enum RemoteCLIWorktreeService {
    /// A paired Mac's request, admitted on `platform` like a local
    /// `graftty worktree add` and recorded with the peer as its origin.
    public static func handle(
        _ request: RemoteWorktreeRequest,
        from device: RemoteDeviceID,
        repos: [RepoEntry],
        platform: any CLIWorktreeCreationPlatform
    ) async -> RemoteTeamResponse {
        let origin: WorktreeHistory.Origin?
        if case .create(let creation) = request { origin = creation.historyOrigin() } else { origin = nil }
        return await handle(request, from: device, repos: repos,
            status: { platform.worktreeCreationStatus(operationID: $0) },
            create: { message in
                guard case .createWorktree(let local) = message else { return .error("Expected local worktree creation") }
                return await CLIWorktreeCreationRequestHandler.begin(local, creationOrigin: origin, platform: platform)
            })
    }

    public static func handle(
        _ request: RemoteWorktreeRequest,
        from device: RemoteDeviceID,
        repos: [RepoEntry],
        status: (String) -> WorktreeCreateStatus?,
        create: (NotificationMessage) async -> ResponseMessage,
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
                        response = await create(.createWorktree(
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
            var progress = result.progress
            progress?.operationID = id
            return .worktreeCreate(.init(operationID: id, state: result.state,
                worktreePath: result.worktreePath, messageAddress: result.worktreePath,
                error: result.error, progress: progress))
        case .error(let message): return .error(message)
        default: return .error("Unexpected local worktree creation response")
        }
    }
}
