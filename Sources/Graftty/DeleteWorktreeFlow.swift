import Foundation
import SwiftUI
import GrafttyKit

/// Shared "remove a worktree" flow used by:
///   - The native sidebar's `MainWindow.performDeleteWorktree`
///   - The web/iOS `POST /worktrees/delete` endpoint
///
/// Both entry points need the same sequence: `git worktree remove` (with
/// GIT-4.13 prune-on-vanished recovery), `git status --short` capture on
/// failure to drive the Force Delete UX (GIT-4.4), surface teardown,
/// per-path cache clears, model removal, and the TEAM-5.3 `left` event.
///
/// Confirmation UX is NOT part of this flow — every entry point owns
/// its own confirmation affordance (NSAlert on macOS, SwiftUI
/// `.confirmationDialog` on iOS), and the flow runs unconditionally
/// once invoked.
///
/// Mirrors `AddWorktreeFlow`'s placement (in the `Graftty` target, not
/// `GrafttyKit`) because `TerminalManager` and the SwiftUI bindings
/// are AppKit-bound.
@MainActor
enum DeleteWorktreeFlow {

    /// Successful outcome carries which branch the flow took so the
    /// caller can label its UI (mac alert message, mobile toast).
    /// `dismissed == true` means we ran `GitWorktreePrune` because the
    /// worktree directory was already gone; `false` means
    /// `git worktree remove` succeeded normally.
    struct Outcome {
        let dismissed: Bool
    }

    enum FlowError: Error {
        /// `git worktree remove` failed in a way `--force` could resolve
        /// (uncommitted/untracked files). Carries stderr + a `git status
        /// --short` snapshot to surface in the failure UI.
        case gitFailedForceable(stderr: String, shortStatus: String)
        /// Failure that `--force` cannot help with: either `--force` was
        /// already attempted, or the failure class is structural (main
        /// checkout, non-git repo, git binary missing).
        case gitFailedFinal(String)
        /// `worktreePath` did not resolve to any tracked worktree.
        case notFound
        /// `worktreePath` resolved to the repo's main checkout, which
        /// `git worktree remove` refuses by design.
        case mainCheckoutRejected
    }

    /// Run the flow. Confirmation must have already happened; this
    /// function performs the irreversible side effects unconditionally.
    static func delete(
        worktreePath: String,
        force: Bool,
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        teamEventDispatcher: TeamEventDispatcher
    ) async -> Swift.Result<Outcome, FlowError> {
        guard let (repoIdx, wtIdx) = appState.wrappedValue.indices(forWorktreePath: worktreePath) else {
            return .failure(.notFound)
        }
        let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
        let repoPath = appState.wrappedValue.repos[repoIdx].path

        if wt.path == repoPath {
            return .failure(.mainCheckoutRejected)
        }
        guard appState.wrappedValue.repos[repoIdx].isGitTracked else {
            return .failure(.gitFailedFinal("not a git repository"))
        }

        do {
            try await GitWorktreeRemove.remove(
                repoPath: repoPath,
                worktreePath: worktreePath,
                force: force
            )
        } catch GitWorktreeRemove.Error.gitFailed(_, let stderr) {
            // GIT-4.13: directory vanished but admin entry survives.
            // `--force` can't bypass git's path validation, so we
            // never offer Force Delete for this branch — we silently
            // prune and treat it as a dismiss.
            if !FileManager.default.fileExists(atPath: worktreePath) {
                try? await GitWorktreePrune.run(repoPath: repoPath)
                finishRemoval(
                    worktree: wt,
                    repoPath: repoPath,
                    appState: appState,
                    terminalManager: terminalManager,
                    statsStore: statsStore,
                    prStatusStore: prStatusStore,
                    teamEventDispatcher: teamEventDispatcher
                )
                return .success(Outcome(dismissed: true))
            }
            if force {
                return .failure(.gitFailedFinal(stderr.isEmpty ? "git worktree remove --force failed" : stderr))
            }
            let status = await GitStatusCapture.shortStatus(at: worktreePath)
            return .failure(.gitFailedForceable(
                stderr: stderr.isEmpty ? "git worktree remove failed" : stderr,
                shortStatus: status
            ))
        } catch {
            return .failure(.gitFailedFinal("\(error)"))
        }

        finishRemoval(
            worktree: wt,
            repoPath: repoPath,
            appState: appState,
            terminalManager: terminalManager,
            statsStore: statsStore,
            prStatusStore: prStatusStore,
            teamEventDispatcher: teamEventDispatcher
        )
        return .success(Outcome(dismissed: false))
    }

    /// Post-remove teardown. Identical ordering to the previous
    /// `MainWindow.finishWorktreeRemoval`: surface teardown for running
    /// worktrees, per-path cache clears BEFORE the model entry drops
    /// (GIT-4.10), then the `removeWorktree` mutation, then the
    /// TEAM-5.3 `left` event whose repo lookup must use the original
    /// `repoPath` because the worktree is gone from AppState by now.
    private static func finishRemoval(
        worktree wt: WorktreeEntry,
        repoPath: String,
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        teamEventDispatcher: TeamEventDispatcher
    ) {
        if wt.state == .running {
            terminalManager.destroySurfaces(terminalIDs: wt.splitTree.allLeaves)
        }
        prStatusStore.clear(worktreePath: wt.path)
        statsStore.clear(worktreePath: wt.path)
        let leaverBranch = wt.branch
        appState.wrappedValue.removeWorktree(atPath: wt.path)
        if let repo = appState.wrappedValue.repo(forWorktreePath: repoPath) {
            TeamMembershipEvents.fireLeft(
                repo: repo,
                leaverBranch: leaverBranch,
                leaverPath: wt.path,
                reason: .removed,
                teamsEnabled: UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled),
                dispatcher: teamEventDispatcher
            )
        }
    }
}
