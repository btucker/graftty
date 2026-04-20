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

    /// Production `ComputeFunction` — resolves the default branch (home
    /// checkout vs linked worktree shape) and computes divergence stats
    /// via the real `GitRunner`. Extracted from the old private-static
    /// `computeOffMain` so tests can inject a stub instead of the real
    /// git subprocess chain. `nonisolated` so `init`'s default-parameter
    /// evaluation (a nonisolated context) can reference it.
    /// Production `FetchFunction` — runs `git fetch` via the real
    /// `GitRunner.run`. `run` throws `CLIError.nonZeroExit` on any
    /// non-zero exit so an offline / auth-failure / rate-limited fetch
    /// propagates as a throw the caller turns into backoff (streak++).
    /// Pre-cycle-140 this used `GitRunner.captureAll` which returns
    /// normally on non-zero exit, so every failed fetch silently
    /// reset the streak and the backoff never kicked in.
    public nonisolated static let defaultFetch: FetchFunction = { repoPath, defaultBranch in
        _ = try await GitRunner.run(
            args: ["fetch", "--no-tags", "--prune", "origin", defaultBranch],
            at: repoPath
        )
    }

    public nonisolated static let defaultCompute: ComputeFunction = { worktreePath, repoPath, cachedDefault in
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
        if let s = result.stats {
            if stats[worktreePath] != s {
                stats[worktreePath] = s
            }
        } else if stats[worktreePath] != nil {
            stats.removeValue(forKey: worktreePath)
        }
    }

    nonisolated static func repoFetchCadence(failureStreak: Int) -> Duration {
        ExponentialBackoff.scale(
            base: .seconds(5 * 60),
            streak: failureStreak,
            cap: .seconds(30 * 60)
        )
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
