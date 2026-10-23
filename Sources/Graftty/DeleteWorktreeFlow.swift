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

    /// Shared with the headless host (GrafttyKit). `dismissed == true`
    /// means the directory was already gone and Git's record was pruned.
    typealias Outcome = WorktreeRemovalOutcome
    typealias FlowError = WorktreeRemovalError

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
        var before = appState.wrappedValue
        defer { GrafttyApp.persistAppStateIfChanged(appState, from: before) }
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

        let priorState = wt.state
        appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .deleting
        // Mark `.deleting` before awaiting git, as the window's `.onChange`
        // would, so a windowless removal is saved and published now
        // (PERF-1.22). The new baseline makes the defer mark a restore too.
        GrafttyApp.persistAppState(appState.wrappedValue)
        before = appState.wrappedValue

        // GIT-4.13: a vanished directory is pruned and reported as a
        // dismissal; Force Delete is never offered for it.
        let result = await GitWorktreeRemove.removeOrPrune(
            repoPath: repoPath,
            worktreePath: worktreePath,
            force: force
        )
        switch result {
        case .success:
            finishRemoval(
                worktree: wt,
                repoPath: repoPath,
                appState: appState,
                terminalManager: terminalManager,
                statsStore: statsStore,
                prStatusStore: prStatusStore,
                teamEventDispatcher: teamEventDispatcher
            )
        case .failure:
            restoreState(priorState, worktreePath: worktreePath, appState: appState)
        }
        return result
    }

    /// Restores the worktree's pre-`.deleting` state after a failed
    /// `git worktree remove`. A no-op if the entry has been removed
    /// from `AppState` in the meantime (e.g. an FSEvents-driven prune
    /// raced ahead).
    private static func restoreState(
        _ prior: WorktreeState,
        worktreePath: String,
        appState: Binding<AppState>
    ) {
        guard let (r, w) = appState.wrappedValue.indices(forWorktreePath: worktreePath) else {
            return
        }
        appState.wrappedValue.repos[r].worktrees[w].state = prior
    }

    /// Post-remove teardown: surface teardown for running and stale
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
        if wt.state == .running || wt.state == .stale {
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
                dispatcher: teamEventDispatcher
            )
        }
    }
}
