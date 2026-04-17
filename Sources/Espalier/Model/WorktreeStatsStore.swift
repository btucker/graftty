import Foundation
import AppKit
import Observation
import EspalierKit

/// Session-scoped, @MainActor-observed store of per-worktree divergence stats.
///
/// Not persisted. Git work is kicked on a child `Task` inherited from the
/// MainActor; the async CLI calls yield rather than block. Publishing back
/// to `stats` happens on the MainActor. Concurrent refresh requests for the
/// same worktree path are deduplicated (DIVERGE-4.4).
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

    @ObservationIgnored
    private var lastRepoFetch: [String: Date] = [:]

    @ObservationIgnored
    private var repoFailureStreak: [String: Int] = [:]

    @ObservationIgnored
    private var inFlightRepos: Set<String> = []

    @ObservationIgnored
    private var ticker: PollingTicker?

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
            self.apply(
                worktreePath: worktreePath,
                repoPath: repoPath,
                result: computed
            )
        }
    }

    public func clear(worktreePath: String) {
        stats.removeValue(forKey: worktreePath)
    }

    /// Start a 5s ticker that periodically `git fetch`es each repo (on its
    /// own cadence — see `repoFetchCadence`) and refreshes stats for every
    /// non-stale worktree on that repo afterward. This replaces the legacy
    /// 60s `Timer` in `EspalierApp.startup()`, and additionally surfaces
    /// origin-side drift (remote moved, local didn't) that `WorktreeMonitor`'s
    /// per-worktree HEAD watcher can't see.
    public func startPolling(appState: AppState) {
        stopPolling()
        let getRepos: () -> [RepoEntry] = { appState.repos }
        let ticker = PollingTicker(interval: .seconds(5))
        self.ticker = ticker
        ticker.start { [weak self] in
            await self?.pollTick(repos: getRepos())
        }
    }

    public func stopPolling() {
        ticker?.stop()
        ticker = nil
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

    /// Per-repo fetch cadence. Base is 5 minutes; each consecutive failure
    /// doubles the interval (capped at 30 minutes) so a flapping remote
    /// doesn't burn cycles. Mirrors `PRStatusStore.cadenceFor`.
    nonisolated static func repoFetchCadence(failureStreak: Int) -> Duration {
        let base: Duration = .seconds(5 * 60)
        if failureStreak == 0 { return base }
        let multiplier = 1 << min(failureStreak, 5)
        let multiplied = base * Int(multiplier)
        let cap: Duration = .seconds(30 * 60)
        return multiplied > cap ? cap : multiplied
    }

    private func pollTick(repos: [RepoEntry]) async {
        let now = Date()
        for repo in repos {
            if inFlightRepos.contains(repo.path) { continue }
            let streak = repoFailureStreak[repo.path] ?? 0
            let interval = Self.repoFetchCadence(failureStreak: streak)
            if let last = lastRepoFetch[repo.path],
               now.timeIntervalSince(last) < Double(interval.components.seconds) {
                continue
            }
            inFlightRepos.insert(repo.path)
            let repoPath = repo.path
            let worktreePaths = repo.worktrees
                .filter { $0.state != .stale }
                .map(\.path)

            Task { [weak self] in
                await self?.performRepoFetch(
                    repoPath: repoPath,
                    worktreePaths: worktreePaths
                )
            }
        }
    }

    private func performRepoFetch(repoPath: String, worktreePaths: [String]) async {
        // `performRepoFetch` is MainActor-isolated (inherited from the class),
        // and `defer` runs after the last `await` resumes on the same actor,
        // so we can mutate `inFlightRepos` synchronously from the defer.
        defer { self.inFlightRepos.remove(repoPath) }

        let defaultBranchResult: String?
        if let cached = defaultBranchByRepo[repoPath] ?? nil {
            defaultBranchResult = cached
        } else {
            defaultBranchResult = (try? await GitOriginDefaultBranch.resolve(repoPath: repoPath)) ?? nil
        }
        self.defaultBranchByRepo[repoPath] = defaultBranchResult
        guard let defaultBranch = defaultBranchResult else {
            self.lastRepoFetch[repoPath] = Date()
            self.repoFailureStreak[repoPath] = 0
            return
        }

        do {
            _ = try await GitRunner.captureAll(
                args: ["fetch", "--no-tags", "--prune", "origin", defaultBranch],
                at: repoPath
            )
            self.lastRepoFetch[repoPath] = Date()
            self.repoFailureStreak[repoPath] = 0
        } catch {
            self.lastRepoFetch[repoPath] = Date()
            self.repoFailureStreak[repoPath, default: 0] += 1
            return
        }

        // Recompute stats for each worktree on this repo after fetch succeeds.
        for wtPath in worktreePaths {
            self.refresh(worktreePath: wtPath, repoPath: repoPath)
        }
    }
}
