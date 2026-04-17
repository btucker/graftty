import Foundation
import Observation
import EspalierKit

/// Session-scoped, @MainActor-observed store of per-worktree divergence stats.
///
/// Not persisted. All git work runs on a background Task.detached; publishing
/// back to `stats` happens on the MainActor. Concurrent refresh requests for
/// the same worktree path are deduplicated (DIVERGE-4.4).
@MainActor
@Observable
public final class WorktreeStatsStore {

    /// Keyed by worktree path. Absent key means "not computed yet or cleared".
    public private(set) var stats: [String: WorktreeStats] = [:]

    /// Cached origin default branch ref per repo path. `.some(nil)` caches a
    /// "no default branch resolvable" result so we don't retry on every poll.
    @ObservationIgnored
    private var defaultBranchByRepo: [String: String?] = [:]

    @ObservationIgnored
    private var inFlight: Set<String> = []

    public init() {}

    public func refresh(worktreePath: String, repoPath: String) {
        guard !inFlight.contains(worktreePath) else { return }
        inFlight.insert(worktreePath)

        Task.detached { [weak self] in
            let computed = await Self.computeOffMain(
                worktreePath: worktreePath,
                repoPath: repoPath,
                cachedDefault: self?.defaultBranchByRepo[repoPath] ?? nil
            )
            await self?.apply(
                worktreePath: worktreePath,
                repoPath: repoPath,
                result: computed
            )
        }
    }

    public func clear(worktreePath: String) {
        stats.removeValue(forKey: worktreePath)
    }

    public func invalidateDefaultBranch(repoPath: String) {
        defaultBranchByRepo.removeValue(forKey: repoPath)
    }

    // MARK: - Private

    /// Result of a background compute attempt. Carries the default branch
    /// discovered (so we can cache it on main) plus the stats or nil if no
    /// default branch exists for this repo.
    private struct ComputeResult: Sendable {
        let defaultBranch: String?
        let stats: WorktreeStats?
    }

    private static func computeOffMain(
        worktreePath: String,
        repoPath: String,
        cachedDefault: String?
    ) async -> ComputeResult {
        let ref: String?
        if let cached = cachedDefault {
            ref = cached
        } else {
            ref = (try? GitOriginDefaultBranch.resolve(repoPath: repoPath)) ?? nil
        }
        guard let ref else {
            return ComputeResult(defaultBranch: nil, stats: nil)
        }
        let stats = try? GitWorktreeStats.compute(
            worktreePath: worktreePath,
            defaultBranchRef: ref
        )
        return ComputeResult(defaultBranch: ref, stats: stats)
    }

    private func apply(
        worktreePath: String,
        repoPath: String,
        result: ComputeResult
    ) {
        inFlight.remove(worktreePath)
        defaultBranchByRepo[repoPath] = result.defaultBranch
        if let s = result.stats {
            stats[worktreePath] = s
        } else {
            stats.removeValue(forKey: worktreePath)
        }
    }
}
