import Foundation
import Observation
import os

@MainActor
@Observable
public final class PRStatusStore {

    public private(set) var infos: [String: PRInfo] = [:]
    public private(set) var absent: Set<String> = []

    @ObservationIgnored private let executor: CLIExecutor
    @ObservationIgnored private let fetcherFor: (HostingProvider) -> PRFetcher?
    @ObservationIgnored private let detectHost: @Sendable (String) async throws -> HostingOrigin?
    @ObservationIgnored private let remoteBranchStore: RemoteBranchStore?
    @ObservationIgnored private var hostByRepo: [String: HostingOrigin?] = [:]
    /// Per-path timestamp of the most recently dispatched fetch. Stored
    /// as a date rather than a bare Set so a hung prior Task (a `gh pr
    /// list` / `gh pr checks` subprocess stuck on an HTTP response or
    /// rate-limit back-off) is considered abandoned after
    /// `refreshCadence`, at which point a new refresh is allowed
    /// through. Bumping `generation` on each allowed refresh drops the
    /// stuck Task's late write if it ever returns. Mirrors
    /// `WorktreeStatsStore`'s DIVERGE-4.4 pattern. `PR-7.13`.
    @ObservationIgnored private var inFlight: [String: Date] = [:]
    @ObservationIgnored private var lastFetch: [String: Date] = [:]
    @ObservationIgnored private var failureStreak: [String: Int] = [:]
    /// Per-path generation counter. Bumped by `clear(worktreePath:)`
    /// and by `refresh`/`tick` dispatches so that an in-flight
    /// `performFetch` can detect when its result has been invalidated —
    /// either by a user-triggered `clear` or by a superseding dispatch
    /// that took over the `inFlight` slot — and bail out before writing
    /// stale data back into `infos`/`absent`.
    @ObservationIgnored private var generation: [String: Int] = [:]
    @ObservationIgnored private var ticker: PollingTickerLike?
    @ObservationIgnored private var getRepos: @MainActor () -> [RepoEntry] = { [] }
    @ObservationIgnored private let logger = Logger(subsystem: "com.btucker.graftty", category: "PRStatusStore")

    /// Fires when a worktree's PR cache transitions into `.merged` for a
    /// PR number that was not previously cached as merged. Set by the app
    /// to drive the "PR merged — delete worktree?" offer dialog. The
    /// callback is intentionally fire-once-per-transition: an idempotent
    /// poll result ("still merged, same PR number") does not re-fire, so
    /// the listener does not need per-PR debouncing.
    @ObservationIgnored public var onPRMerged: (@MainActor (_ worktreePath: String, _ prNumber: Int) -> Void)?

    /// Fires on PR state or CI-conclusion transitions for a tracked
    /// worktree. Idempotent polls (same info twice) do not fire. The
    /// initial discovery of a PR (previous == nil) does not fire — a
    /// transition requires a previous state to transition FROM.
    ///
    /// Delivers a `(RoutableEvent, worktreePath, attrs)` tuple. The body
    /// string is reconstructable from `attrs` via
    /// `RoutableEvent.defaultBody(attrs:)` — the consumer typically wraps
    /// it back into a `ChannelServerMessage.event(...)` before handing it
    /// to `TeamEventDispatcher.dispatchRoutableEvent(...)`.
    @ObservationIgnored public var onTransition: (@MainActor (_ event: RoutableEvent, _ worktreePath: String, _ attrs: [String: String]) -> Void)?

    public init(
        executor: CLIExecutor = CLIRunner(),
        fetcherFor: ((HostingProvider) -> PRFetcher?)? = nil,
        detectHost: (@Sendable (String) async throws -> HostingOrigin?)? = nil,
        remoteBranchStore: RemoteBranchStore? = nil
    ) {
        self.executor = executor
        self.remoteBranchStore = remoteBranchStore
        if let fetcherFor {
            self.fetcherFor = fetcherFor
        } else {
            let cap = executor
            self.fetcherFor = { provider in
                switch provider {
                case .github: return GitHubPRFetcher(executor: cap)
                case .gitlab: return GitLabPRFetcher(executor: cap)
                case .unsupported: return nil
                }
            }
        }
        if let detectHost {
            self.detectHost = detectHost
        } else {
            self.detectHost = { repoPath in
                try await GitOriginHost.detect(repoPath: repoPath)
            }
        }
    }

    /// Force a fetch for one worktree, regardless of cadence. Silently
    /// no-ops for git sentinel branches (`(detached)` / `(bare)` /
    /// `(unknown)` / unborn / empty) that cannot correspond to a real
    /// `refs/heads/` value — `PR-7.5`. Defers to an in-flight prior
    /// fetch only while that fetch is plausibly still running
    /// (`PR-7.13`): beyond the `refreshCadence` cap, the prior Task is
    /// treated as abandoned (stuck `gh` subprocess) and a fresh fetch
    /// supersedes it. Bumping `generation` ensures the abandoned Task's
    /// late write is dropped if it ever returns.
    public func refresh(worktreePath: String, repoPath: String, branch: String) {
        guard Self.isFetchableBranch(branch) else { return }
        guard hasRemoteBranch(repoPath: repoPath, branch: branch) else {
            markLocallyUnpushed(worktreePath)
            return
        }
        let now = Date()
        let cap = Double(Self.refreshCadence().components.seconds)
        if let started = inFlight[worktreePath],
           now.timeIntervalSince(started) < cap {
            return
        }
        inFlight[worktreePath] = now
        generation[worktreePath, default: 0] += 1

        // Snapshot synchronously — a `clear()` between here and Task
        // start must invalidate this fetch. `PR-7.9`.
        let fetchGeneration = generation[worktreePath, default: 0]
        Task { [weak self] in
            await self?.performFetch(
                worktreePath: worktreePath,
                repoPath: repoPath,
                branch: branch,
                fetchGeneration: fetchGeneration
            )
        }
    }

    public func clear(worktreePath: String) {
        // Guard the observable mutations so a no-op clear (worktree never
        // had a cached PR) doesn't fire `@Observable` notifications and
        // re-render every SidebarView row.
        if infos[worktreePath] != nil {
            infos.removeValue(forKey: worktreePath)
        }
        if absent.contains(worktreePath) {
            absent.remove(worktreePath)
        }
        lastFetch.removeValue(forKey: worktreePath)
        failureStreak.removeValue(forKey: worktreePath)
        // Release the in-flight gate so a subsequent `refresh` isn't
        // silently suppressed while the prior Task drains. The Task's
        // late write is handled by the generation check in
        // `performFetch`.
        inFlight.removeValue(forKey: worktreePath)
        // Bump the generation so any in-flight fetch's late write
        // (after its await resumes) can detect it's been invalidated
        // and discard its result.
        generation[worktreePath, default: 0] += 1
    }

    // Test hooks — not used in production. Kept internal so they're
    // reachable from GrafttyKitTests without widening the public API.
    func generationForTesting(_ worktreePath: String) -> Int {
        generation[worktreePath, default: 0]
    }

    func isInFlightForTesting(_ worktreePath: String) -> Bool {
        inFlight[worktreePath] != nil
    }

    func beginInFlightForTesting(_ worktreePath: String) {
        inFlight[worktreePath] = Date()
    }

    /// Seed the in-flight timestamp so tests can simulate a prior
    /// refresh Task that's been pending longer than `refreshCadence`
    /// — i.e., considered abandoned. A subsequent `refresh` call must
    /// then dispatch a fresh Task rather than silently deferring to the
    /// stuck one. Mirrors `WorktreeStatsStore.seedInFlightSinceForTesting`.
    func seedInFlightSinceForTesting(_ date: Date, forWorktree worktreePath: String) {
        inFlight[worktreePath] = date
    }

    /// Notify the store that a worktree's branch has changed. Drops the
    /// cached PR info synchronously so the UI doesn't keep showing the
    /// previous branch's PR through the gh-fetch in-flight window, then
    /// schedules a fresh fetch for the new branch — `clear` already
    /// released the `inFlight` gate, so the subsequent `refresh` won't
    /// be suppressed by a concurrent polling-cycle fetch.
    public func branchDidChange(worktreePath: String, repoPath: String, branch: String) {
        clear(worktreePath: worktreePath)
        refresh(worktreePath: worktreePath, repoPath: repoPath, branch: branch)
    }

    // MARK: - Fetch

    private func performFetch(
        worktreePath: String,
        repoPath: String,
        branch: String,
        fetchGeneration: Int
    ) async {
        // Release the in-flight slot only if our generation is still
        // the current one. A superseding dispatch (user `clear`, branch
        // change, or a `PR-7.13` stuck-Task recovery) already took over
        // the slot with its own timestamp; blindly removing here would
        // let yet another dispatch race in alongside the live one.
        // Mirrors `WorktreeStatsStore.apply`'s release discipline.
        defer {
            if generation[worktreePath, default: 0] == fetchGeneration {
                inFlight.removeValue(forKey: worktreePath)
            }
        }

        // Caller snapshotted `fetchGeneration`; we re-read `generation`
        // after each await and bail on mismatch so a `clear()` during
        // the fetch drops the stale write.
        let origin: HostingOrigin?
        if let cached = hostByRepo[repoPath] {
            origin = cached
        } else {
            // Only cache on success. A thrown CLIError (git missing
            // from PATH, spawn failure) would otherwise poison the
            // cache for the session. `PR-7.11`. Log at debug level —
            // polls can fire many times while the env is misconfigured.
            do {
                let detected = try await detectHost(repoPath)
                origin = detected
                hostByRepo[repoPath] = detected
            } catch {
                logger.debug("host detect failed for \(repoPath): \(String(describing: error))")
                origin = nil
            }
        }
        if generation[worktreePath, default: 0] != fetchGeneration { return }
        guard let origin, origin.provider != .unsupported,
              let fetcher = fetcherFor(origin.provider) else {
            markAbsent(worktreePath)
            lastFetch[worktreePath] = Date()
            return
        }

        do {
            let pr = try await fetcher.fetch(origin: origin, branch: branch)
            if generation[worktreePath, default: 0] != fetchGeneration { return }
            lastFetch[worktreePath] = Date()
            failureStreak[worktreePath] = 0
            if let pr {
                // Fire-once transition detection: callback is invoked
                // when this fetch lands on a merged PR whose number
                // wasn't already cached as merged. Covers nil→merged,
                // open→merged, and merged-N→merged-M. Same-PR
                // merged→merged re-fetches (the steady-state poll
                // result) do nothing.
                let prev = infos[worktreePath]
                let justMerged = pr.state == .merged
                    && (prev?.state != .merged || prev?.number != pr.number)
                detectAndFireTransitions(
                    worktreePath: worktreePath,
                    previous: prev,
                    current: pr,
                    origin: origin
                )
                if prev != pr {
                    infos[worktreePath] = pr
                }
                if absent.contains(worktreePath) {
                    absent.remove(worktreePath)
                }
                if justMerged, let onPRMerged {
                    onPRMerged(worktreePath, pr.number)
                }
            } else {
                if infos[worktreePath] != nil {
                    infos.removeValue(forKey: worktreePath)
                }
                markAbsent(worktreePath)
            }
        } catch {
            if generation[worktreePath, default: 0] != fetchGeneration { return }
            logger.info("PR fetch failed for \(worktreePath): \(String(describing: error))")
            failureStreak[worktreePath, default: 0] += 1
            lastFetch[worktreePath] = Date()
            // `PR-7.10`: leave `infos[worktreePath]` untouched. A
            // transient failure isn't evidence the PR stopped
            // existing; the next successful fetch reconciles.
        }
    }

    private func markAbsent(_ worktreePath: String) {
        if !absent.contains(worktreePath) {
            absent.insert(worktreePath)
        }
    }

    private func markLocallyUnpushed(_ worktreePath: String) {
        var invalidatedInFlight = false

        if infos[worktreePath] != nil {
            infos.removeValue(forKey: worktreePath)
        }
        if absent.contains(worktreePath) {
            absent.remove(worktreePath)
        }
        lastFetch.removeValue(forKey: worktreePath)
        failureStreak.removeValue(forKey: worktreePath)
        if inFlight.removeValue(forKey: worktreePath) != nil {
            invalidatedInFlight = true
        }
        if invalidatedInFlight {
            generation[worktreePath, default: 0] += 1
        }
    }

    private func hasRemoteBranch(repoPath: String, branch: String) -> Bool {
        guard let remoteBranchStore else { return true }
        return remoteBranchStore.hasRemote(repoPath: repoPath, branch: branch)
    }

    private func hasRemoteBranch(for worktree: WorktreeEntry, repoPath: String) -> Bool {
        hasRemoteBranch(repoPath: repoPath, branch: worktree.branch)
    }

    private func detectAndFireTransitions(
        worktreePath: String,
        previous: PRInfo?,
        current: PRInfo,
        origin: HostingOrigin
    ) {
        guard let onTransition else { return }
        guard let previous else { return }  // initial discovery: not a transition

        // Early return before the dict-allocation path when nothing changed.
        guard previous.state != current.state || previous.checks != current.checks else {
            return
        }

        let common: [String: String] = [
            "pr_number": String(current.number),
            "pr_url": current.url.absoluteString,
            "provider": origin.provider.rawValue,
            "repo": origin.slug,
            "worktree": worktreePath,
        ]

        if previous.state != current.state {
            var attrs = common
            attrs["from"] = previous.state.rawValue
            attrs["to"] = current.state.rawValue
            attrs["pr_title"] = current.title
            let routable: RoutableEvent = (current.state == .merged) ? .prMerged : .prStateChanged
            onTransition(routable, worktreePath, attrs)
        }

        if previous.checks != current.checks {
            var attrs = common
            attrs["from"] = previous.checks.rawValue
            attrs["to"] = current.checks.rawValue
            onTransition(.ciConclusionChanged, worktreePath, attrs)
        }
    }

    /// Test seam so tests can exercise transition detection without
    /// spinning up a fetcher. `internal` so `@testable import` reaches it
    /// from `GrafttyKitTests` without widening the public surface.
    internal func detectAndFireTransitionsForTesting(
        worktreePath: String,
        previous: PRInfo?,
        current: PRInfo,
        origin: HostingOrigin
    ) {
        detectAndFireTransitions(
            worktreePath: worktreePath,
            previous: previous, current: current, origin: origin
        )
    }
}

extension PRStatusStore {

    /// `GitWorktreeDiscovery` encodes git's non-branch worktree states
    /// as the sentinel strings `"(detached)"`, `"(bare)"`, and
    /// `"(unknown)"`. None of them correspond to a real `refs/heads/`
    /// value, so passing them to `gh pr list --head <branch>` guarantees
    /// an empty result — two wasted `gh` invocations per polling tick,
    /// per affected worktree. Skip at the fetch-gate.
    public nonisolated static func isFetchableBranch(_ branch: String) -> Bool {
        // Anything wrapped in parens is a sentinel from parsePorcelain;
        // keep the check liberal so new sentinels added upstream (e.g.
        // `(unborn)`) don't silently start incurring fetches.
        if branch.hasPrefix("(") && branch.hasSuffix(")") { return false }
        // Defensive: empty/whitespace also can't be a branch.
        return !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Time-bound cap on the `inFlight` guard (`PR-7.13`). A normal
    /// `gh pr list` + `gh pr checks` pair resolves in under a few seconds;
    /// anything in-flight longer than this is assumed abandoned (stuck
    /// subprocess, rate-limit back-off, auth retry loop) and superseded by
    /// the next dispatch. Independent of `cadenceFor` — the poll cadence
    /// can be tighter (e.g. 10s while CI is pending) without shrinking
    /// this stuck-guard window, which would otherwise kill legitimately
    /// slow `gh` calls.
    nonisolated static func refreshCadence() -> Duration {
        .seconds(30)
    }

    nonisolated static func cadenceFor(
        info: PRInfo?,
        isAbsent: Bool,
        failureStreak: Int
    ) -> Duration {
        // PR-7.1: 10s while CI is pending (so green/red transitions land in
        // the breadcrumb within one polling window); 30s for any other
        // known state — open/merged with non-pending checks, or absent.
        // Polling is the only detection channel for an open→merged
        // transition that lands on the hosting provider without a local
        // `git fetch`, so cadence directly governs user-visible staleness.
        let base: Duration
        if info?.checks == .pending {
            base = .seconds(10)
        } else if info != nil || isAbsent {
            base = .seconds(30)
        } else {
            base = .zero
        }
        // PR-7.2: cap at 60s. Higher caps (the prior 30-minute ceiling)
        // produce silent staleness — `PR-7.10` preserves last-known
        // `PRInfo` on failure, so the breadcrumb sits confidently on data
        // that's drifted up to half an hour out of date with no visual
        // cue. Cap and floor happen to coincide at 60s; they serve
        // distinct purposes — the floor only kicks in when `base ==
        // .zero` (unknown-state guard, prevents hammering a broken CLI
        // every tick), the cap clamps the backoff multiplier for every
        // tier. They're not a single value masquerading as two.
        return ExponentialBackoff.scale(
            base: base,
            streak: failureStreak,
            cap: .seconds(60),
            floor: .seconds(60)
        )
    }

    func cadence(for worktreePath: String) -> Duration {
        Self.cadenceFor(
            info: infos[worktreePath],
            isAbsent: absent.contains(worktreePath),
            failureStreak: failureStreak[worktreePath] ?? 0
        )
    }

    public func start(
        ticker: PollingTickerLike,
        getRepos: @escaping @MainActor () -> [RepoEntry]
    ) {
        stop()
        self.getRepos = getRepos
        self.ticker = ticker
        ticker.start { [weak self] in
            await self?.tick()
        }
    }

    public func stop() {
        ticker?.stop()
        ticker = nil
    }

    public func pulse() {
        ticker?.pulse()
    }

    private func tick() async {
        let repos = getRepos()
        let now = Date()
        let inFlightCap = Double(Self.refreshCadence().components.seconds)

        struct Candidate { let path, repoPath, branch: String }
        var candidates: [Candidate] = []

        for repo in repos {
            // If host resolution already concluded "no origin" or "unsupported",
            // skip. Uncached repos fall through — performFetch resolves on first run.
            if let cached = hostByRepo[repo.path],
               cached == nil || cached?.provider == .unsupported {
                continue
            }
            for wt in repo.worktrees where wt.state.hasOnDiskWorktree {
                if !Self.isFetchableBranch(wt.branch) { continue }
                guard hasRemoteBranch(for: wt, repoPath: repo.path) else {
                    markLocallyUnpushed(wt.path)
                    continue
                }
                // `PR-7.13` time-bounded in-flight check: defer to a
                // prior dispatch only while it's plausibly still
                // running. Past the cap it's treated as abandoned and
                // a fresh fetch supersedes it below.
                if let started = inFlight[wt.path],
                   now.timeIntervalSince(started) < inFlightCap {
                    continue
                }
                let interval = cadence(for: wt.path)
                let last = lastFetch[wt.path]
                if let last, now.timeIntervalSince(last) < Double(interval.components.seconds) {
                    continue
                }
                candidates.append(Candidate(path: wt.path, repoPath: repo.path, branch: wt.branch))
            }
        }

        for c in candidates {
            inFlight[c.path] = Date()
            generation[c.path, default: 0] += 1
            let gen = generation[c.path, default: 0]
            Task { [weak self] in
                await self?.performFetch(
                    worktreePath: c.path,
                    repoPath: c.repoPath,
                    branch: c.branch,
                    fetchGeneration: gen
                )
            }
        }
    }
}
