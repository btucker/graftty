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

    /// Cached origin default branch name (e.g. `"main"`) per repo path.
    /// `.some(nil)` caches a "no default branch resolvable" result so we
    /// don't retry on every poll. The name (not the ref) is stored because
    /// home and linked worktrees form different refs from it.
    @ObservationIgnored
    private var defaultBranchByRepo: [String: String?] = [:]

    @ObservationIgnored
    private var inFlight: Set<String> = []

    public init() {}

    public func refresh(worktreePath: String, repoPath: String) {
        guard !inFlight.contains(worktreePath) else { return }
        inFlight.insert(worktreePath)
        let cached = defaultBranchByRepo[repoPath] ?? nil

        Task {
            let computed = await Self.computeOffMain(
                worktreePath: worktreePath,
                repoPath: repoPath,
                cachedDefault: cached
            )
            await MainActor.run {
                self.apply(
                    worktreePath: worktreePath,
                    repoPath: repoPath,
                    result: computed
                )
            }
        }
    }

    public func clear(worktreePath: String) {
        stats.removeValue(forKey: worktreePath)
    }

    /// Returns the full base ref used for divergence computation for a
    /// given worktree, or nil if the default branch hasn't been resolved
    /// yet / isn't resolvable. Mirrors `computeOffMain`'s home-vs-linked
    /// rule so the UI can render the same label the gutter's numbers
    /// were measured against (e.g. "vs. origin/main" for the main
    /// checkout, "vs. main" for a linked worktree).
    public func baseRef(worktreePath: String, repoPath: String) -> String? {
        guard let name = defaultBranchByRepo[repoPath] ?? nil else { return nil }
        let isHomeWorktree = (worktreePath == repoPath)
        return isHomeWorktree ? "origin/\(name)" : name
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
        let name: String?
        if let cached = cachedDefault {
            name = cached
        } else {
            name = (try? await GitOriginDefaultBranch.resolve(repoPath: repoPath)) ?? nil
        }
        guard let name else {
            return ComputeResult(defaultBranch: nil, stats: nil)
        }
        // Home checkout (path == repo.path) compares against `origin/<name>`
        // so the indicator surfaces unpushed work. Linked worktrees compare
        // against the local `<name>` branch so feature branches show
        // divergence from where they were branched rather than double-
        // counting commits that are already on local main.
        let isHomeWorktree = (worktreePath == repoPath)
        let baseRef = isHomeWorktree ? "origin/\(name)" : name
        let stats = try? await GitWorktreeStats.compute(
            worktreePath: worktreePath,
            defaultBranchRef: baseRef
        )
        return ComputeResult(defaultBranch: name, stats: stats)
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
