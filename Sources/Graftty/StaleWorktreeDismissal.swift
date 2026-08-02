import Foundation
import SwiftUI
import GrafttyKit
import GrafttyProtocol

/// Shared teardown path for manual and automatic dismissal of stale
/// worktrees. Keeping the ordering here ensures neither entry point can
/// remove the model row while leaving its terminal surfaces alive.
@MainActor
enum StaleWorktreeDismissal {
    typealias SurfaceDestroyer = ([PaneSlotID]) -> Void
    typealias PathCleaner = (String) -> Void
    typealias WorktreeDiscoverer = (RepoEntry) async throws -> [DiscoveredWorktree]

    @discardableResult
    static func dismiss(
        worktreeID: WorktreeEntry.ID,
        appState: Binding<AppState>,
        destroySurfaces: SurfaceDestroyer,
        clearPRStatus: PathCleaner,
        clearStats: PathCleaner
    ) -> Bool {
        guard let (repoIndex, worktreeIndex) = indices(
            for: worktreeID,
            in: appState.wrappedValue
        ) else {
            return false
        }
        let worktree = appState.wrappedValue
            .repos[repoIndex].worktrees[worktreeIndex]
        guard worktree.state == .stale else {
            return false
        }

        // GIT-3.10: stale-while-running entries can still own live
        // libghostty surfaces. Tear them down before the row disappears.
        let orphanedPanes = appState.wrappedValue
            .repos[repoIndex].worktrees[worktreeIndex]
            .prepareForDismissal()
        if !orphanedPanes.isEmpty {
            destroySurfaces(orphanedPanes)
        }

        // Clear path-keyed observable state before model removal so no
        // orphan cache survives a later same-path worktree re-add.
        clearPRStatus(worktree.path)
        clearStats(worktree.path)
        return appState.wrappedValue.removeWorktree(
            atPath: worktree.path
        ) != nil
    }

    @discardableResult
    static func dismissExpired(
        appState: Binding<AppState>,
        now: Date,
        gracePeriod: TimeInterval = StaleWorktreeAutoDismissPolicy.defaultGracePeriod,
        discoverWorktrees: WorktreeDiscoverer,
        destroySurfaces: SurfaceDestroyer,
        clearPRStatus: PathCleaner,
        clearStats: PathCleaner,
        onDismiss: (AppState) -> Void = { _ in }
    ) async -> [WorktreeEntry.ID] {
        let expired = Set(StaleWorktreeAutoDismissPolicy.expiredWorktreeIDs(
            in: appState.wrappedValue,
            now: now,
            gracePeriod: gracePeriod
        ))
        let candidates: [(
            repo: RepoEntry,
            worktrees: [(id: WorktreeEntry.ID, staleSince: Date)]
        )] =
            appState.wrappedValue.repos.compactMap { repo in
                let worktrees: [(id: WorktreeEntry.ID, staleSince: Date)] =
                    repo.worktrees.compactMap { worktree in
                        guard expired.contains(worktree.id),
                              let staleSince = worktree.staleSince else {
                            return nil
                        }
                        return (id: worktree.id, staleSince: staleSince)
                    }
                return worktrees.isEmpty ? nil : (repo, worktrees)
            }

        var dismissed: [WorktreeEntry.ID] = []
        for candidate in candidates {
            let discovered: [DiscoveredWorktree]
            do {
                discovered = try await discoverWorktrees(candidate.repo)
            } catch {
                // Discovery is the authoritative resurrection check. If it
                // is unavailable, preserve the rows and retry next tick.
                NSLog(
                    "[Graftty] stale auto-dismiss discovery failed for %@: %@",
                    candidate.repo.path,
                    String(describing: error)
                )
                continue
            }

            // The await above permits relocation or repository removal.
            // Results from the old path must not authorize teardown in the
            // new repository location.
            guard let currentRepo = appState.wrappedValue.repos.first(where: {
                $0.id == candidate.repo.id && $0.path == candidate.repo.path
            }) else { continue }

            let discoveredPaths = Set(discovered.lazy
                .filter { !$0.isPrunable }
                .map(\.path))
            for candidateWorktree in candidate.worktrees {
                guard let worktree = currentRepo.worktrees.first(where: {
                    $0.id == candidateWorktree.id
                }), worktree.state == .stale,
                    worktree.staleSince == candidateWorktree.staleSince,
                    now.timeIntervalSince(candidateWorktree.staleSince) >= gracePeriod,
                    !discoveredPaths.contains(worktree.path) else {
                    continue
                }
                if dismiss(
                    worktreeID: candidateWorktree.id,
                    appState: appState,
                    destroySurfaces: destroySurfaces,
                    clearPRStatus: clearPRStatus,
                    clearStats: clearStats
                ) {
                    dismissed.append(candidateWorktree.id)
                    onDismiss(appState.wrappedValue)
                }
            }
        }
        return dismissed
    }

    private static func indices(
        for worktreeID: WorktreeEntry.ID,
        in appState: AppState
    ) -> (repo: Int, worktree: Int)? {
        for repoIndex in appState.repos.indices {
            if let worktreeIndex = appState.repos[repoIndex].worktrees
                .firstIndex(where: { $0.id == worktreeID }) {
                return (repoIndex, worktreeIndex)
            }
        }
        return nil
    }
}
