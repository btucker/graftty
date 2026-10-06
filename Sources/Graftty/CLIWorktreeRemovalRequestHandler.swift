import GrafttyKit
import SwiftUI

/// Validates CLI removal against live app state before any removal side effects.
@MainActor
enum CLIWorktreeRemovalRequestHandler {
    static func begin(
        worktreePath: String,
        force: Bool,
        pinned: Bool,
        appState: Binding<AppState>,
        worktreeRemovals: CLIWorktreeRemovalStore,
        wakeWorktree: (String) -> Bool,
        deleteWorktree: @escaping @MainActor (String, Bool) async -> Result<DeleteWorktreeFlow.Outcome, DeleteWorktreeFlow.FlowError>
    ) -> ResponseMessage {
        if let error = validationError(worktreePath: worktreePath, pinned: pinned, state: appState.wrappedValue) {
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
            if let error = validationError(worktreePath: worktreePath, pinned: pinned, state: appState.wrappedValue) {
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
