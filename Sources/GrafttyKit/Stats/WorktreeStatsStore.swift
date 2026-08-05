import Foundation
import Observation

/// Session-scoped, @MainActor-observed store of per-worktree divergence stats.
///
/// Not persisted. Git work is kicked on a child `Task` inherited from the
/// MainActor; the async CLI calls yield rather than block. Publishing back
/// to `stats` happens on the MainActor. Concurrent refresh requests for the
/// same worktree path are coalesced into one trailing refresh
/// (DIVERGE-4.4).
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

    /// Per-path timestamp of the most recently dispatched `refresh`.
    /// Stored as a date rather than a boolean so a hung prior Task
    /// (e.g., a `git` subprocess blocked on a ref-transaction lock
    /// during a concurrent `git push`) can be considered abandoned
    /// after `inFlightAbandonmentThreshold`, at which point a new
    /// refresh is allowed through. Bumping the generation on each
    /// allowed refresh drops the stuck Task's late `apply` when it
    /// eventually returns.
    @ObservationIgnored
    private var inFlight: [String: Date] = [:]

    /// Latest request received while a per-path computation is still in
    /// flight. Event-driven HEAD/origin refreshes can arrive behind a
    /// polling computation that captured older refs; retaining one
    /// trailing request prevents that authoritative final signal from
    /// being dropped. Newer requests replace older ones.
    @ObservationIgnored
    private var pendingRefresh: [String: RefreshRequest] = [:]

    private struct RefreshRequest {
        let repoPath: String
        let branch: String
    }

    /// Per-path generation counter. Bumped by `clear(worktreePath:)`
    /// and by `refresh(…)` so a superseded in-flight fetch's late
    /// `apply` can detect it's been invalidated and drop its write —
    /// otherwise a fetch that started before a user-triggered `clear`
    /// (Dismiss, Delete, stale transition) or before a stuck-Task
    /// supersession would repopulate `stats` with data that no longer
    /// reflects either the user's intent or the current git state.
    /// Mirrors `PRStatusStore`'s pattern. DIVERGE-4.5.
    @ObservationIgnored
    private var generation: [String: Int] = [:]

    @ObservationIgnored
    private var lastRepoFetch: [String: Date] = [:]

    @ObservationIgnored
    private var repoFailureStreak: [String: Int] = [:]

    /// Per-repo timestamp of the most recently dispatched `git fetch`,
    /// stored as a date (not a `Set` membership) for the same reason as
    /// the per-path `inFlight` map: although `git fetch` has a 20-second
    /// subprocess deadline, task scheduling or termination delivery can
    /// still be delayed across sleep/wake. That can keep
    /// `performRepoFetch` from reaching its slot-releasing `defer`. A
    /// bare `Set` would then latch the repo's path forever:
    /// every poll short-circuits at the in-flight check, Gate B is
    /// skipped, and the divergence gutter freezes until relaunch. The
    /// timestamp lets `repoFetchDisposition` treat a slot older than
    /// `inFlightAbandonmentThreshold` as abandoned and dispatch a fresh
    /// fetch (DIVERGE-4.11 — the async-hang sibling of the synchronous
    /// latch closed by DIVERGE-4.10). Mirrors `inFlight`'s DIVERGE-4.4
    /// abandonment.
    @ObservationIgnored
    private var inFlightRepos: [String: Date] = [:]

    @ObservationIgnored
    private var ticker: PollingTickerLike?

    @ObservationIgnored
    private var getRepos: @MainActor () -> [RepoEntry] = { [] }

    @ObservationIgnored
    private var pollCursor = RoundRobinBatchCursor()

    /// Network fetches use a separate cursor so a due tick cannot enqueue the
    /// whole workspace ahead of remote-ref, PR, or event-driven stats work.
    @ObservationIgnored
    private var repoFetchCursor = RoundRobinBatchCursor()

    private struct PollCandidate {
        let worktreePath: String
        let repoPath: String
        let branch: String
    }

    private enum RepoFetchDisposition {
        case inFlight
        case due
        case notDue
    }

    /// Event-driven file-system refreshes are the prompt path. The recurring
    /// poll is only a repair mechanism for missed events, so cap its dispatch
    /// volume as well as the number of pipelines allowed to run concurrently.
    private static let pollBatchSize = 4

    /// The compute function invoked off-main to resolve the default
    /// branch and divergence stats. Injected so tests can supply a
    /// controllable stub (yielding at a chosen point, returning canned
    /// output) without having to mutate the global `GitRunner.executor`
    /// — which races with concurrent test suites. In production this
    /// defaults to `Self.defaultCompute` which uses the real GitRunner.
    @ObservationIgnored
    private let compute: ComputeFunction

    /// Bounds the number of five-subprocess divergence pipelines that can be
    /// active at once. Together with `pollBatchSize`, a large workspace no
    /// longer turns a safety-net tick or event burst into an unbounded group
    /// of `git` children competing with terminal input.
    @ObservationIgnored
    private let backgroundProcessLimiter: BackgroundProcessLimiter

    /// Signature of the compute injection point. Sendable so the
    /// detached-from-MainActor Task can invoke it safely. `branch` is
    /// the worktree's current branch name from `WorktreeEntry.branch`
    /// (empty when detached HEAD / unknown) — required so the base ref
    /// can prefer `origin/<branch>` for per-worktree origin tracking.
    public typealias ComputeFunction = @Sendable (
        _ worktreePath: String,
        _ repoPath: String,
        _ branch: String,
        _ cachedDefault: String?
    ) async -> ComputeResult

    /// Result of a background compute attempt. `defaultBranch` is cached
    /// on main regardless of whether stats landed; `stats` carries its
    /// own `upstreamRefs` so the UI tooltip shows the actual ref
    /// measured against (`WorktreeStats.upstreamRefs.displayLabel`).
    /// `stats == nil` with `defaultBranch != nil` is a transient compute
    /// failure (`DIVERGE-4.9`); `defaultBranch == nil` means the repo
    /// has no resolvable default and the gutter should render nothing.
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
        _ repoPath: String
    ) async throws -> Void

    public init(
        compute: @escaping ComputeFunction = WorktreeStatsStore.defaultCompute,
        fetch: @escaping FetchFunction = WorktreeStatsStore.defaultFetch,
        backgroundProcessLimiter: BackgroundProcessLimiter = BackgroundProcessLimiter(capacity: 4)
    ) {
        self.compute = compute
        self.fetch = fetch
        self.backgroundProcessLimiter = backgroundProcessLimiter
    }

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
    func performRepoFetchForTesting(
        repoPath: String,
        worktrees: [(path: String, branch: String)] = [],
        dispatchedAt: Date? = nil
    ) async {
        await performRepoFetch(
            repoPath: repoPath,
            worktrees: worktrees,
            dispatchedAt: dispatchedAt ?? inFlightRepos[repoPath] ?? Date()
        )
    }

    /// Seed the repo's cached default-branch so
    /// `performRepoFetchForTesting` reaches the fetch call instead of
    /// short-circuiting at the resolve-default-branch step.
    func seedDefaultBranchForTesting(_ branch: String, forRepo repoPath: String) {
        defaultBranchByRepo[repoPath] = branch
    }

    func isInFlightForTesting(_ worktreePath: String) -> Bool {
        inFlight[worktreePath] != nil
    }

    /// Seed the per-repo in-flight `git fetch` marker so tests can
    /// simulate a prior fetch Task that hung past
    /// `inFlightAbandonmentThreshold` — i.e., considered abandoned. A
    /// subsequent `pollTick` must then dispatch a fresh fetch rather
    /// than latching forever on the stuck slot. DIVERGE-4.11.
    func seedInFlightRepoForTesting(_ date: Date, forRepo repoPath: String) {
        inFlightRepos[repoPath] = date
    }

    func isInFlightRepoForTesting(_ repoPath: String) -> Bool {
        inFlightRepos[repoPath] != nil
    }

    /// Seed the in-flight timestamp so tests can simulate a prior
    /// refresh Task that's been pending longer than
    /// `inFlightAbandonmentThreshold` — i.e., considered abandoned. A
    /// subsequent `refresh` call must then dispatch a fresh Task rather
    /// than silently deferring to the stuck one.
    func seedInFlightSinceForTesting(_ date: Date, forWorktree worktreePath: String) {
        inFlight[worktreePath] = date
    }

    /// Drives `pollTick` from tests so the per-tick refresh behavior
    /// can be exercised end-to-end. `pollTick` remains private so
    /// production callers go through `start(ticker:)`, but a
    /// controllable entry point is required to test that the per-repo
    /// fetch cooldown does not gate the per-worktree stats recompute.
    func pollTickForTesting(repos: [RepoEntry]) async {
        await pollTick(repos: repos)
    }

    /// Seed the per-repo fetch timestamp so `pollTick`'s fetch gate
    /// treats the repo as "already fetched recently" and falls through
    /// to the per-worktree refresh branch.
    func seedLastRepoFetchForTesting(_ date: Date, forRepo repoPath: String) {
        lastRepoFetch[repoPath] = date
    }

    public func refresh(worktreePath: String, repoPath: String, branch: String) {
        let now = Date()
        // Defer to an in-flight refresh only while its Task is plausibly
        // still running. A normal compute completes in milliseconds, so
        // anything older than `inFlightAbandonmentThreshold` is assumed
        // abandoned (the common path is a `git` subprocess blocked on a
        // ref-transaction lock during a concurrent `git push`, which
        // doesn't respond to Task cancellation). Beyond the threshold
        // we fall through and dispatch a new Task; bumping `generation`
        // ensures the stuck Task's late `apply` is dropped if it ever
        // returns.
        let cap = Double(Self.inFlightAbandonmentThreshold().components.seconds)
        if let started = inFlight[worktreePath],
           now.timeIntervalSince(started) < cap {
            pendingRefresh[worktreePath] = RefreshRequest(
                repoPath: repoPath,
                branch: branch
            )
            return
        }
        // A dispatch past the abandonment threshold supersedes both the
        // active Task and any trailing request queued behind it.
        pendingRefresh.removeValue(forKey: worktreePath)
        inFlight[worktreePath] = now
        generation[worktreePath, default: 0] += 1
        let cached = defaultBranchByRepo[repoPath] ?? nil
        let fetchGeneration = generation[worktreePath, default: 0]
        let compute = self.compute
        let backgroundProcessLimiter = self.backgroundProcessLimiter

        Task {
            let computed: ComputeResult? = await backgroundProcessLimiter.run { [weak self] in
                // The in-flight timestamp starts when refresh() queues the
                // work so later requests coalesce while it waits. Reset it
                // once a permit is obtained, giving the actual subprocess
                // pipeline its full abandonment window. If clear() or an
                // abandoned-task replacement changed the generation while
                // this request waited, skip the now-obsolete work entirely.
                guard let self,
                      await self.beginLimitedCompute(
                        worktreePath: worktreePath,
                        fetchGeneration: fetchGeneration
                      ) else { return nil }
                return await compute(worktreePath, repoPath, branch, cached)
            }
            guard let computed else { return }
            self.apply(
                worktreePath: worktreePath,
                repoPath: repoPath,
                result: computed,
                fetchGeneration: fetchGeneration
            )
        }
    }

    private func beginLimitedCompute(
        worktreePath: String,
        fetchGeneration: Int
    ) -> Bool {
        guard generation[worktreePath, default: 0] == fetchGeneration else {
            return false
        }
        inFlight[worktreePath] = Date()
        return true
    }

    public func clear(worktreePath: String) {
        stats.removeValue(forKey: worktreePath)
        // Release the in-flight gate so a subsequent `refresh` isn't
        // silently suppressed while the prior Task drains. The Task's
        // late `apply` is handled by the generation check.
        inFlight.removeValue(forKey: worktreePath)
        pendingRefresh.removeValue(forKey: worktreePath)
        // Bump the generation so any in-flight fetch's late apply
        // (after its await resumes) detects the invalidation and drops
        // the write instead of repopulating stats for a dismissed
        // worktree. Mirrors PRStatusStore.clear. DIVERGE-4.5.
        generation[worktreePath, default: 0] += 1
    }

    /// Start the polling loop with a caller-provided ticker. The ticker
    /// lives in the app target (it needs AppKit) and is injected so this
    /// store can live in GrafttyKit without dragging in AppKit. Mirrors
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

    /// Display label for the upstream refs the most recent successful
    /// compute measured against, for the sidebar tooltip. Nil until the
    /// first successful compute lands.
    public func baseRef(worktreePath: String, repoPath: String) -> String? {
        stats[worktreePath]?.upstreamRefs?.displayLabel
    }

    // MARK: - Private

    /// Production `FetchFunction` — runs `git fetch` via `GitRunner.run`
    /// with no explicit refspec, so the remote's configured fetch rules
    /// (`remote.origin.fetch` = `+refs/heads/*:refs/remotes/origin/*` on
    /// a clone) advance every tracked branch. Passing only
    /// `<defaultBranch>` — the pre-fix shape — left `origin/<feature>`
    /// frozen at whatever commit it was during the last manual fetch, so
    /// polling couldn't surface teammate pushes on a linked worktree's
    /// own branch. `run` throws on non-zero exit so the caller's backoff
    /// (streak++) still fires on offline / auth / rate-limit failures.
    public nonisolated static let defaultFetch: FetchFunction = { repoPath in
        _ = try await GitRunner.run(
            args: ["fetch", "--no-tags", "--prune", "origin"],
            at: repoPath,
            // Bound the network fetch below the in-flight abandonment
            // threshold (30s) so a wedged socket is SIGTERMed and throws
            // here — releasing the `inFlightRepos` slot via `defer` and
            // feeding the backoff — rather than being silently superseded
            // and leaking the hung subprocess (DIVERGE-4.11).
            timeout: WorktreeStatsStore.fetchTimeout()
        )
    }

    /// Subprocess timeout for the poll-driven `git fetch`. Comfortably
    /// above a healthy incremental fetch (sub-second to a few seconds)
    /// yet below `inFlightAbandonmentThreshold` (30s) so a hung fetch
    /// fails and releases its slot before the abandonment path would
    /// otherwise have to supersede it.
    nonisolated static func fetchTimeout() -> Duration {
        .seconds(20)
    }

    /// Local Git can also block indefinitely when repository metadata is
    /// an iCloud placeholder or another filesystem provider stalls a read.
    /// Keep the deadline below the 30-second in-flight replacement threshold
    /// so the child is terminated before a later poll may supersede it.
    nonisolated static func localCommandTimeout() -> Duration {
        .seconds(20)
    }

    /// Production `ComputeFunction` — resolves the default branch,
    /// picks the per-worktree upstream refs, and computes divergence
    /// via `GitRunner`. `nonisolated` so `init`'s default-parameter
    /// evaluation can reference it.
    public nonisolated static let defaultCompute: ComputeFunction = makeDefaultCompute()

    /// Builds the production compute pipeline around one absolute deadline.
    /// The executor seam keeps timeout-propagation tests independent of
    /// `GitRunner`'s legacy process-global test override.
    nonisolated static func makeDefaultCompute(
        executor: CLIExecutor? = nil,
        timeout: Duration = localCommandTimeout()
    ) -> ComputeFunction {
        { worktreePath, repoPath, branch, cachedDefault in
            let deadline = GitCommandDeadline(timeout: timeout)
            let name: String?
            if let cached = cachedDefault {
                name = cached
            } else {
                name = await GitOriginDefaultBranch.resolve(
                    repoPath: repoPath,
                    deadline: deadline,
                    using: executor
                )
            }
            guard let name else {
                return ComputeResult(defaultBranch: nil, stats: nil)
            }
            let refs = await GitWorktreeStats.resolveUpstreamRefs(
                worktreePath: worktreePath,
                branch: branch,
                defaultBranch: name,
                deadline: deadline,
                using: executor
            )
            let stats = try? await GitWorktreeStats.compute(
                worktreePath: worktreePath,
                upstreamRefs: refs,
                deadline: deadline,
                using: executor
            )
            return ComputeResult(defaultBranch: name, stats: stats)
        }
    }

    private func apply(
        worktreePath: String,
        repoPath: String,
        result: ComputeResult,
        fetchGeneration: Int
    ) {
        // Repo-level cache is path-agnostic; always update it.
        defaultBranchByRepo[repoPath] = result.defaultBranch
        // DIVERGE-4.5: drop the stats write if the caller's clear() or
        // a superseding `refresh` invalidated us while the git
        // subprocess was running. Leave `inFlight` untouched in that
        // case — the live Task owns its own in-flight slot and will
        // clear it when its own apply lands. Otherwise release the
        // in-flight gate so the next cadence tick can dispatch again.
        if generation[worktreePath, default: 0] != fetchGeneration { return }
        inFlight.removeValue(forKey: worktreePath)
        let pending = pendingRefresh.removeValue(forKey: worktreePath)

        // Publish every generation-valid completion before starting its
        // trailing refresh. If a normal computation takes longer than the
        // polling interval, another tick can otherwise perpetually queue a
        // successor and suppress every completed snapshot.
        if let s = result.stats {
            if stats[worktreePath] != s {
                stats[worktreePath] = s
            }
        } else if result.defaultBranch == nil {
            stats.removeValue(forKey: worktreePath)
        }
        // `DIVERGE-4.9`: nil stats with a resolved defaultBranch
        // means compute threw — preserve the last-known ↑N ↓M.

        if let pending {
            refresh(
                worktreePath: worktreePath,
                repoPath: pending.repoPath,
                branch: pending.branch
            )
        }
    }

    nonisolated static func repoFetchCadence(failureStreak: Int) -> Duration {
        ExponentialBackoff.scale(
            base: .seconds(30),
            streak: failureStreak,
            cap: .seconds(30 * 60)
        )
    }

    /// Threshold past which a still-`inFlight` refresh Task is treated
    /// as abandoned (DIVERGE-4.4) and superseded by a new dispatch. A
    /// normal compute completes in milliseconds; the typical hung path
    /// is a `git` subprocess blocked on a ref-transaction lock during a
    /// concurrent `git push`, which doesn't respond to Task cancellation
    /// — without this threshold the worktree's gutter would lock at
    /// whatever value was observed during the lock window. 30s mirrors
    /// `PRStatusStore.refreshCadence()` (the PR store's in-flight
    /// abandonment cap) for symmetry across the two per-worktree stores.
    nonisolated static func inFlightAbandonmentThreshold() -> Duration {
        .seconds(30)
    }

    private func pollTick(repos: [RepoEntry]) async {
        let now = Date()
        var fetchCandidates: [RepoEntry] = []
        var statsCandidates: [PollCandidate] = []

        for repo in repos where repo.isGitTracked {
            switch repoFetchDisposition(repo: repo, now: now) {
            case .inFlight:
                // The live fetch will recompute this repo's worktrees.
                continue
            case .due:
                fetchCandidates.append(repo)
            case .notDue:
                appendStatsCandidates(for: repo, to: &statsCandidates)
            }
        }

        let liveFetchCount = inFlightRepos.values.filter {
            now.timeIntervalSince($0)
                < Double(Self.inFlightAbandonmentThreshold().components.seconds)
        }.count
        let availableFetchSlots = max(0, Self.pollBatchSize - liveFetchCount)
        let fetchBatch = availableFetchSlots > 0
            ? repoFetchCursor.nextBatch(
                from: fetchCandidates,
                maximumCount: availableFetchSlots,
                path: \.path
            )
            : []
        let fetchedRepoPaths = Set(fetchBatch.map(\.path))
        for repo in fetchBatch {
            dispatchRepoFetch(repo: repo, now: now)
        }

        // A due repo outside this tick's network batch remains eligible for a
        // cheap local recompute. Only repos with an active or newly dispatched
        // fetch are skipped because their fetch handler owns the recompute.
        for repo in fetchCandidates where !fetchedRepoPaths.contains(repo.path) {
            appendStatsCandidates(for: repo, to: &statsCandidates)
        }

        let statsBatch = pollCursor.nextBatch(
            from: statsCandidates,
            maximumCount: Self.pollBatchSize,
            path: \.worktreePath
        )
        for candidate in statsBatch {
            refresh(
                worktreePath: candidate.worktreePath,
                repoPath: candidate.repoPath,
                branch: candidate.branch
            )
        }
    }

    private func appendStatsCandidates(
        for repo: RepoEntry,
        to candidates: inout [PollCandidate]
    ) {
        for worktree in repo.worktrees where shouldPollStats(for: worktree) {
            candidates.append(PollCandidate(
                worktreePath: worktree.path,
                repoPath: repo.path,
                branch: worktree.branch
            ))
        }
    }

    private func repoFetchDisposition(
        repo: RepoEntry,
        now: Date
    ) -> RepoFetchDisposition {
        // Defer to an in-flight fetch only while it's plausibly still
        // running. Although `git fetch` has a 20-second subprocess
        // deadline, task scheduling or termination delivery can still be
        // delayed across sleep/wake and keep `performRepoFetch` from
        // reaching its slot-releasing `defer`. Past the abandonment
        // threshold we treat the slot as dead and fall through to
        // dispatch a fresh fetch — otherwise the repo latches here
        // permanently, Gate B is skipped every tick, and the divergence
        // gutter freezes until relaunch (DIVERGE-4.11).
        let cap = Double(Self.inFlightAbandonmentThreshold().components.seconds)
        if let started = inFlightRepos[repo.path],
           now.timeIntervalSince(started) < cap {
            return .inFlight
        }
        let streak = repoFailureStreak[repo.path] ?? 0
        let interval = Self.repoFetchCadence(failureStreak: streak)
        if let last = lastRepoFetch[repo.path],
           now.timeIntervalSince(last) < Double(interval.components.seconds) {
            return .notDue
        }
        // DIVERGE-4.10: claiming an `inFlightRepos` slot here without a
        // matching `performRepoFetch` (whose `defer` releases the slot)
        // permanently latches the repo — every subsequent poll then classifies
        // it as active and Gate B never re-fires for a worktree the user later
        // opens.
        guard repo.worktrees.contains(where: shouldPollStats) else {
            return .notDue
        }
        return .due
    }

    private func dispatchRepoFetch(repo: RepoEntry, now: Date) {
        inFlightRepos[repo.path] = now
        let dispatchedAt = now
        let repoPath = repo.path
        let worktrees = repo.worktrees
            .filter(shouldPollStats)
            .map { (path: $0.path, branch: $0.branch) }
        let backgroundProcessLimiter = self.backgroundProcessLimiter

        Task {
            await backgroundProcessLimiter.run { [weak self] in
                guard let self,
                      let startedAt = await self.beginLimitedRepoFetch(
                        repoPath: repoPath,
                        dispatchedAt: dispatchedAt
                      ) else { return }
                await self.performRepoFetch(
                    repoPath: repoPath,
                    worktrees: worktrees,
                    dispatchedAt: startedAt
                )
            }
        }
    }

    private func beginLimitedRepoFetch(
        repoPath: String,
        dispatchedAt: Date
    ) -> Date? {
        // The slot may have been superseded while this fetch waited behind
        // other background work. Skip obsolete requests; otherwise reset the
        // timestamp so the actual network process gets its full abandonment
        // window rather than counting time suspended in the limiter queue.
        guard inFlightRepos[repoPath] == dispatchedAt else { return nil }
        let startedAt = Date()
        inFlightRepos[repoPath] = startedAt
        return startedAt
    }

    private func shouldPollStats(for worktree: WorktreeEntry) -> Bool {
        worktree.state == .running
    }

    func performRepoFetch(
        repoPath: String,
        worktrees: [(path: String, branch: String)],
        dispatchedAt: Date
    ) async {
        // Release the slot only if it's still the one this Task claimed.
        // The slot timestamp doubles as the ownership token: if this
        // fetch hung past `inFlightAbandonmentThreshold` and a later tick
        // superseded it, that tick overwrote `inFlightRepos[repoPath]` with
        // its own later timestamp, so the
        // equality fails here and the stale Task declines to clear the live
        // slot. Same intent as `apply`'s generation guard (DIVERGE-4.5),
        // expressed with the unique dispatch `Date` rather than an Int
        // counter since the timestamp is already needed for the age check.
        defer {
            if self.inFlightRepos[repoPath] == dispatchedAt {
                self.inFlightRepos.removeValue(forKey: repoPath)
            }
        }

        let defaultBranchResult: String?
        if let cached = defaultBranchByRepo[repoPath] ?? nil {
            defaultBranchResult = cached
        } else {
            defaultBranchResult = await GitOriginDefaultBranch.resolve(
                repoPath: repoPath,
                timeout: Self.localCommandTimeout()
            )
        }
        self.defaultBranchByRepo[repoPath] = defaultBranchResult
        guard defaultBranchResult != nil else {
            self.lastRepoFetch[repoPath] = Date()
            self.repoFailureStreak[repoPath] = 0
            return
        }

        do {
            try await fetch(repoPath)
            self.lastRepoFetch[repoPath] = Date()
            self.repoFailureStreak[repoPath] = 0
        } catch {
            self.lastRepoFetch[repoPath] = Date()
            self.repoFailureStreak[repoPath, default: 0] += 1
            return
        }

        // Recompute stats for each active worktree on this repo after fetch succeeds.
        for wt in worktrees {
            self.refresh(worktreePath: wt.path, repoPath: repoPath, branch: wt.branch)
        }
    }
}
