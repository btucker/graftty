import Foundation
import GrafttyProtocol

/// Host-specific effects behind `graftty worktree remove`.
@MainActor
public protocol CLIWorktreeRemovalPlatform: AnyObject {
    var state: AppState { get set }
    var worktreeRemovals: CLIWorktreeRemovalStore { get }
    /// Resumes a sleeping worktree's processes; false if they cannot resume.
    func wakeWorktree(_ path: String) -> Bool
    /// Removes a linked worktree from Git and the model.
    func removeWorktree(_ path: String, force: Bool) async -> Result<WorktreeRemovalOutcome, WorktreeRemovalError>
}

/// Validates `graftty worktree remove` against live host state before any
/// removal side effects, then runs the host's removal in the background.
/// Shared by the Mac app and the headless host.
@MainActor
public enum CLIWorktreeRemovalRequestHandler {
    public static func begin(
        worktreePath: String,
        force: Bool,
        pinned: Bool,
        state: @escaping @MainActor () -> AppState,
        worktreeRemovals: CLIWorktreeRemovalStore,
        wakeWorktree: (String) -> Bool,
        deleteWorktree: @escaping @MainActor (String, Bool) async -> Result<WorktreeRemovalOutcome, WorktreeRemovalError>
    ) -> ResponseMessage {
        if let error = validationError(worktreePath: worktreePath, pinned: pinned, state: state()) {
            return .error(error)
        }
        guard !worktreeRemovals.hasPendingRemoval(worktreePath: worktreePath) else {
            return .error("worktree removal is already in progress")
        }
        guard wakeWorktree(worktreePath) else {
            return .error("Could not resume worktree processes. Retry before interacting with this worktree.")
        }

        let status = worktreeRemovals.begin(worktreePath: worktreePath)
        Task { @MainActor in
            // Admission and task execution are separate actor turns. A row
            // may become pinned before this task starts. Recheck before Git,
            // including the vanished-directory prune/dismiss recovery path.
            if let error = validationError(worktreePath: worktreePath, pinned: pinned, state: state()) {
                worktreeRemovals.markFailed(operationID: status.operationID, error: error, forceAllowed: false)
                return
            }
            let result = await deleteWorktree(worktreePath, force)
            switch result {
            case .success:
                worktreeRemovals.markRemoved(operationID: status.operationID)
            case .failure(.gitFailedForceable(let stderr, let shortStatus)):
                worktreeRemovals.markFailed(
                    operationID: status.operationID,
                    error: stderr,
                    forceAllowed: true,
                    shortStatus: shortStatus.isEmpty ? nil : shortStatus
                )
            case .failure(.gitFailedFinal(let message)):
                worktreeRemovals.markFailed(operationID: status.operationID, error: message, forceAllowed: false)
            case .failure(.notFound):
                worktreeRemovals.markFailed(operationID: status.operationID, error: "unknown worktree", forceAllowed: false)
            case .failure(.mainCheckoutRejected):
                worktreeRemovals.markFailed(operationID: status.operationID, error: "cannot remove the main checkout", forceAllowed: false)
            }
        }
        return .worktreeRemove(status)
    }

    private static func validationError(worktreePath: String, pinned: Bool, state: AppState) -> String? {
        guard let (repoIndex, worktreeIndex) = state.indices(forWorktreePath: worktreePath) else {
            return "unknown worktree"
        }
        let repo = state.repos[repoIndex]
        let worktree = repo.worktrees[worktreeIndex]
        guard worktree.path != repo.path else {
            return "cannot remove the main checkout"
        }
        guard pinned || !worktree.isPinned else {
            return "worktree is pinned; rerun with --pinned to authorize removal; --force does not bypass pin protection"
        }
        guard !worktree.state.isInFlight else {
            return "a worktree operation is already in progress"
        }
        return nil
    }
}
