import Foundation
import Observation

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

    /// Per-path generation counter. Bumped by `clear(worktreePath:)` so
    /// an in-flight fetch's late `apply` can detect it's been invalidated
    /// and drop its write — otherwise a fetch that started before a
    /// user-triggered `clear` (Dismiss, Delete, stale transition) would
    /// repopulate `stats` with data for a worktree the user just
    /// dismissed. Mirrors `PRStatusStore`'s pattern. DIVERGE-4.5.
    @ObservationIgnored
    private var generation: [String: Int] = [:]

    @ObservationIgnored
    private var lastRepoFetch: [String: Date] = [:]

    @ObservationIgnored
    private var repoFailureStreak: [String: Int] = [:]

    @ObservationIgnored
    private var inFlightRepos: Set<String> = []

    /// Last successful stats compute per worktree. Used to gate the
    /// per-worktree recompute cadence (DIVERGE-4.6), which runs at 30s
    /// independent of the 5-minute `git fetch` cadence. FSEvents on the
    /// worktree contents (GIT-2.6) drives the common case; this poll is
    /// a safety net for bursts the FSEvents coalescer ate and for
    /// changes that happened while the app was backgrounded.
    @ObservationIgnored
    private var lastStatsRefresh: [String: Date] = [:]

    @ObservationIgnored
    private var ticker: PollingTickerLike?

    @ObservationIgnored
    private var getRepos: @MainActor () -> [RepoEntry] = { [] }

    /// The compute function invoked off-main to resolve the default
    /// branch and divergence stats. Injected so tests can supply a
    /// controllable stub (yielding at a chosen point, returning canned
    /// output) without having to mutate the global `GitRunner.executor`
    /// — which races with concurrent test suites. In production this
    /// defaults to `Self.defaultCompute` which uses the real GitRunner.
    @ObservationIgnored
    private let compute: ComputeFunction

    /// Signature of the compute injection point. Sendable so the
    /// detached-from-MainActor Task can invoke it safely.
    public typealias ComputeFunction = @Sendable (
        _ worktreePath: String,
        _ repoPath: String,
        _ cachedDefault: String?
    ) async -> ComputeResult

    /// Result of a background compute attempt. Carries the default branch
    /// discovered (so we can cache it on main) plus the stats or nil if no
    /// default branch exists for this repo.
    public struct ComputeResult: Sendable {
        public let defaultBranch: String?
        public let stats: WorktreeStats?

        public init(defaultBranch: String?, stats: WorktreeStats?) {
            self.defaultBranch = defaultBranch
            self.stats = stats
        }
    }

    /// Runs `git fetch` for the repo. Throwing means the fetch failed —
    /// caller increments `repoFailureStreak` and applies exponential
    /// backoff. Injected so tests can drive the failure path
    /// deterministically without mutating the global `GitRunner.executor`
    /// (which poisoned concurrent test suites in cycle 122).
    @ObservationIgnored
    private let fetch: FetchFunction

    /// Signature of the fetch injection point.
    public typealias FetchFunction = @Sendable (
        _ repoPath: String,
        _ defaultBranch: String
    ) async throws -> Void

    public init(
        compute: @escaping ComputeFunction = WorktreeStatsStore.defaultCompute,
        fetch: @escaping FetchFunction = WorktreeStatsStore.defaultFetch
    ) {
        self.compute = compute
        self.fetch = fetch
    }

    // Test hooks for DIVERGE-4.5 verification. Not used in production.
    func generationForTesting(_ worktreePath: String) -> Int {
        generation[worktreePath, default: 0]
    }

    /// Test-only accessor for the per-repo fetch failure streak used by
    /// `ExponentialBackoff.scale`. Exposed internal so tests can observe
    /// that a non-zero `git fetch` exit correctly increments the streak
    /// rather than being silently treated as success.
    func repoFailureStreakForTesting(_ repoPath: String) -> Int {
        repoFailureStreak[repoPath, default: 0]
    }

    /// Drives `performRepoFetch` from tests without going through the
    /// private `pollTick`. `internal` visibility avoids making the real
    /// method public; tests use `@testable import`.
    func performRepoFetchForTesting(repoPath: String, worktreePaths: [String]) async {
        await performRepoFetch(repoPath: repoPath, worktreePaths: worktreePaths)
    }

    /// Seed the repo's cached default-branch so
    /// `performRepoFetchForTesting` reaches the fetch call instead of
    /// short-circuiting at the resolve-default-branch step.
    func seedDefaultBranchForTesting(_ branch: String, forRepo repoPath: String) {
        defaultBranchByRepo[repoPath] = branch
    }

    func isInFlightForTesting(_ worktreePath: String) -> Bool {
        inFlight.contains(worktreePath)
    }

    /// Drives `pollTick` from tests so the DIVERGE-4.6 per-worktree
    /// cadence gate can be exercised end-to-end. `pollTick` remains
    /// private so production callers go through `start(ticker:)`, but a
    /// controllable entry point is required to test that the per-repo
    /// fetch cooldown does not gate the per-worktree stats recompute.
    func pollTickForTesting(repos: [RepoEntry]) async {
        await pollTick(repos: repos)
    }

    /// Seed the per-repo fetch timestamp so `pollTick`'s fetch gate
    /// treats the repo as "already fetched recently" and falls through
    /// to the per-worktree stats cadence branch.
    func seedLastRepoFetchForTesting(_ date: Date, forRepo repoPath: String) {
        lastRepoFetch[repoPath] = date
    }

    /// Seed the per-worktree stats timestamp so `pollTick`'s stats
    /// cadence gate treats the worktree as "recently recomputed".
    func seedLastStatsRefreshForTesting(_ date: Date, forWorktree worktreePath: String) {
        lastStatsRefresh[worktreePath] = date
    }

    public func refresh(worktreePath: String, repoPath: String) {
        guard !inFlight.contains(worktreePath) else { return }
        inFlight.insert(worktreePath)
        let cached = defaultBranchByRepo[repoPath] ?? nil
        let fetchGeneration = generation[worktreePath, default: 0]
        let compute = self.compute

        Task {
            let computed = await compute(worktreePath, repoPath, cached)
            self.apply(
                worktreePath: worktreePath,
                repoPath: repoPath,
                result: computed,
                fetchGeneration: fetchGeneration
            )
        }
    }

    public func clear(worktreePath: String) {
        stats.removeValue(forKey: worktreePath)
        // Release the in-flight gate so a subsequent `refresh` isn't
        // silently suppressed while the prior Task drains. The Task's
        // late `apply` is handled by the generation check.
        inFlight.remove(worktreePath)
        // Bump the generation so any in-flight fetch's late apply
        // (after its await resumes) detects the invalidation and drops
        // the write instead of repopulating stats for a dismissed
        // worktree. Mirrors PRStatusStore.clear. DIVERGE-4.5.
        generation[worktreePath, default: 0] += 1
    }

    /// Start the polling loop with a caller-provided ticker. The ticker
    /// lives in the app target (it needs AppKit) and is injected so this
    /// store can live in EspalierKit without dragging in AppKit. Mirrors
    /// `PRStatusStore.start` and enables unit-testing DIVERGE-4.5 via a
    /// stub PollingTickerLike + stubbed GitRunner executor.
    public func start(
        ticker: PollingTickerLike,
        getRepos: @escaping @MainActor () -> [RepoEntry]
    ) {
        stop()
        self.getRepos = getRepos
        self.ticker = ticker
        let repos = getRepos
        ticker.start { [weak self] in
            await self?.pollTick(repos: repos())
        }
    }

    public func stop() {
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

    /// Production `FetchFunction` — runs `git fetch` via `GitRunner.run`.
    /// `run` throws on non-zero exit so the caller's backoff (streak++)
    /// fires on offline / auth-failure / rate-limited fetches.
    public nonisolated static let defaultFetch: FetchFunction = { repoPath, defaultBranch in
        _ = try await GitRunner.run(
            args: ["fetch", "--no-tags", "--prune", "origin", defaultBranch],
            at: repoPath
        )
    }

    /// Production `ComputeFunction` — resolves the default branch and
    /// computes divergence via `GitRunner`. `nonisolated` so `init`'s
    /// default-parameter evaluation can reference it.
    public nonisolated static let defaultCompute: ComputeFunction = { worktreePath, repoPath, cachedDefault in
        let name: String?
        if let cached = cachedDefault {
            name = cached
        } else {
            name = await GitOriginDefaultBranch.resolve(repoPath: repoPath)
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
        result: ComputeResult,
        fetchGeneration: Int
    ) {
        inFlight.remove(worktreePath)
        // The repo-level default-branch cache is path-agnostic and a
        // valid side-effect regardless of whether the worktree-scoped
        // stats write is still current, so always update it.
        defaultBranchByRepo[repoPath] = result.defaultBranch
        // DIVERGE-4.5: drop the stats write if the caller's clear()
        // invalidated us while the git subprocess was running.
        if generation[worktreePath, default: 0] != fetchGeneration { return }
        // Gate the stats cadence off successful computes only — an errored
        // compute (result.stats == nil while defaultBranch is resolvable)
        // shouldn't reset the clock, otherwise a repeatedly-failing
        // subprocess (e.g. `git rev-list` aborted on a corrupted pack)
        // would silently pace itself at the full cadence instead of
        // retrying on the next tick.
        if result.stats != nil || result.defaultBranch == nil {
            lastStatsRefresh[worktreePath] = Date()
        }
        if let s = result.stats {
            if stats[worktreePath] != s {
                stats[worktreePath] = s
            }
        } else if result.defaultBranch == nil {
            // No default branch → no divergence to compute against.
            if stats[worktreePath] != nil {
                stats.removeValue(forKey: worktreePath)
            }
        }
        // `DIVERGE-4.9`: nil stats with a resolved defaultBranch
        // means compute threw — preserve the last-known ↑N ↓M.
    }

    nonisolated static func repoFetchCadence(failureStreak: Int) -> Duration {
        ExponentialBackoff.scale(
            base: .seconds(5 * 60),
            streak: failureStreak,
            cap: .seconds(30 * 60)
        )
    }

    /// DIVERGE-4.6: per-worktree local stats recompute cadence. Runs
    /// against the local git working tree, so it's cheap (no network)
    /// and gated independently of `repoFetchCadence`'s 5-minute network
    /// fetch cadence. 30s base matches `PRStatusStore.cadenceFor` so
    /// both rows of the sidebar refresh on the same tempo.
    nonisolated static func statsRefreshCadence() -> Duration {
        .seconds(30)
    }

    private func pollTick(repos: [RepoEntry]) async {
        let now = Date()
        let statsInterval = Self.statsRefreshCadence()
        for repo in repos {
            // Gate A: network `git fetch` on the 5-min cadence (DIVERGE-4.3).
            // On success, performRepoFetch also kicks per-worktree refreshes,
            // so we don't double-fire them in Gate B below for the same tick.
            let didDispatchRepoFetch = maybeDispatchRepoFetch(repo: repo, now: now)

            // Gate B: cheap local stats recompute per worktree (DIVERGE-4.6).
            // Skips any worktree the repo-fetch dispatch already scheduled —
            // `performRepoFetch` calls `refresh(worktreePath:)` for each
            // non-stale worktree after its fetch resolves.
            if didDispatchRepoFetch { continue }
            for wt in repo.worktrees where wt.state != .stale {
                if inFlight.contains(wt.path) { continue }
                if let last = lastStatsRefresh[wt.path],
                   now.timeIntervalSince(last) < Double(statsInterval.components.seconds) {
                    continue
                }
                refresh(worktreePath: wt.path, repoPath: repo.path)
            }
        }
    }

    /// Returns true if a repo-level fetch was dispatched this tick. The
    /// pollTick caller uses that to skip its per-worktree Gate B, since
    /// `performRepoFetch` will itself refresh every worktree in the repo
    /// after the fetch — double-firing would waste subprocess work and
    /// bump `inFlight` churn unnecessarily.
    private func maybeDispatchRepoFetch(repo: RepoEntry, now: Date) -> Bool {
        if inFlightRepos.contains(repo.path) { return true }
        let streak = repoFailureStreak[repo.path] ?? 0
        let interval = Self.repoFetchCadence(failureStreak: streak)
        if let last = lastRepoFetch[repo.path],
           now.timeIntervalSince(last) < Double(interval.components.seconds) {
            return false
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
        return true
    }

    private func performRepoFetch(repoPath: String, worktreePaths: [String]) async {
        defer { self.inFlightRepos.remove(repoPath) }

        let defaultBranchResult: String?
        if let cached = defaultBranchByRepo[repoPath] ?? nil {
            defaultBranchResult = cached
        } else {
            defaultBranchResult = await GitOriginDefaultBranch.resolve(repoPath: repoPath)
        }
        self.defaultBranchByRepo[repoPath] = defaultBranchResult
        guard let defaultBranch = defaultBranchResult else {
            self.lastRepoFetch[repoPath] = Date()
            self.repoFailureStreak[repoPath] = 0
            return
        }

        do {
            try await fetch(repoPath, defaultBranch)
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
