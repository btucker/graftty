import Foundation
import Observation
import os

/// PR/MR status store. Polls per-repo (one host CLI call per repo
/// per tick) and distributes the snapshot to every worktree whose
/// branch matches a PR head. The public surface
/// (`infos[worktreePath]`, `absent`, `refresh`, `branchDidChange`,
/// `clear`) is unchanged so views keep working — only the fetch
/// path is repo-batched.
///
/// @spec PR-8.16
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

    /// All per-repo polling state collapsed into a single value.
    /// `inFlightSince` doubles as the abandoned-fetch detector: a
    /// dispatch older than `refreshCadence` is treated as stuck
    /// and superseded by the next one. `generation` increments on
    /// every dispatch so a stuck Task's late write is dropped.
    /// @spec PR-8.17
    private struct RepoFetchState {
        var inFlightSince: Date?
        var lastFetch: Date?
        var failureStreak: Int = 0
        var generation: Int = 0
    }
    @ObservationIgnored private var fetchStateByRepo: [String: RepoFetchState] = [:]

    @ObservationIgnored private var ticker: PollingTickerLike?
    @ObservationIgnored private var getRepos: @MainActor () -> [RepoEntry] = { [] }
    @ObservationIgnored private let logger = Logger(subsystem: "com.btucker.graftty", category: "PRStatusStore")

    /// Fires when a worktree's PR cache transitions into `.merged`
    /// for a PR number that was not previously cached as merged.
    /// Drives the "PR merged — delete worktree?" offer dialog.
    @ObservationIgnored public var onPRMerged: (@MainActor (_ worktreePath: String, _ prNumber: Int) -> Void)?

    /// Fires on PR state, CI-conclusion, or mergeable-state transitions
    /// for a tracked worktree. Idempotent polls (same info twice) do not
    /// fire. The initial discovery of a PR (previous == nil) does not
    /// fire — a transition requires a previous state to transition FROM.
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

    /// Force a fetch for the repo containing this worktree,
    /// bypassing the polling cadence. The previous per-branch
    /// refresh path is gone: a single repo fetch covers every
    /// worktree, and one in-flight fetch satisfies a refresh
    /// request for any of the repo's worktrees. Silently no-ops
    /// for git sentinel branches (`(detached)` / `(bare)` /
    /// `(unknown)` / unborn / empty) — `PR-7.5`.
    public func refresh(worktreePath: String, repoPath: String, branch: String) {
        guard Self.isFetchableBranch(branch) else { return }
        guard hasRemoteBranch(repoPath: repoPath, branch: branch) else {
            markLocallyUnpushed(worktreePath)
            return
        }
        dispatchRepoFetch(repoPath: repoPath, force: true)
    }

    public func clear(worktreePath: String) {
        markLocallyUnpushed(worktreePath)
    }

    /// Notify the store that a worktree's branch has changed.
    /// Drops the cached PR info synchronously — the UI mustn't
    /// keep showing the old branch's PR through the fetch
    /// in-flight window — and forces a repo refresh.
    public func branchDidChange(worktreePath: String, repoPath: String, branch: String) {
        clear(worktreePath: worktreePath)
        refresh(worktreePath: worktreePath, repoPath: repoPath, branch: branch)
    }

    // MARK: - Test hooks

    func generationForTesting(_ repoPath: String) -> Int {
        fetchStateByRepo[repoPath]?.generation ?? 0
    }

    func isInFlightForTesting(_ repoPath: String) -> Bool {
        fetchStateByRepo[repoPath]?.inFlightSince != nil
    }

    /// Seed the in-flight timestamp so tests can simulate a prior
    /// refresh Task that's been pending longer than `refreshCadence`
    /// — i.e., considered abandoned. A subsequent `refresh` call
    /// must then dispatch a fresh Task rather than silently
    /// deferring to the stuck one.
    func seedInFlightSinceForTesting(_ date: Date, forRepo repoPath: String) {
        fetchStateByRepo[repoPath, default: RepoFetchState()].inFlightSince = date
    }

    /// Seed the last-fetch timestamp so tests can simulate enough
    /// wall time having passed that the polling cadence guard
    /// (`!force` branch in `dispatchRepoFetch`) won't suppress a
    /// non-forced `tick`. Pair with `seedInFlightSinceForTesting`
    /// when fast-forwarding both the in-flight cap and the cadence.
    func seedLastFetchForTesting(_ date: Date, forRepo repoPath: String) {
        fetchStateByRepo[repoPath, default: RepoFetchState()].lastFetch = date
    }

    func applyInfoForTesting(worktreePath: String, info: PRInfo) {
        infos[worktreePath] = info
    }

    func markAbsentForTesting(_ worktreePath: String) {
        markAbsent(worktreePath)
    }

    // MARK: - Fetch dispatch

    /// Returns true if the dispatch went through; false if it was
    /// suppressed (cadence, in-flight, or unsupported host).
    @discardableResult
    private func dispatchRepoFetch(repoPath: String, force: Bool) -> Bool {
        if let cached = hostByRepo[repoPath],
           cached == nil || cached?.provider == .unsupported {
            return false
        }
        let now = Date()
        let inFlightCap = Double(Self.refreshCadence().components.seconds)
        var state = fetchStateByRepo[repoPath, default: RepoFetchState()]
        if let started = state.inFlightSince,
           now.timeIntervalSince(started) < inFlightCap {
            return false
        }
        if !force, let last = state.lastFetch {
            let interval = Double(Self.cadenceFor(failureStreak: state.failureStreak).components.seconds)
            if now.timeIntervalSince(last) < interval {
                return false
            }
        }

        state.inFlightSince = now
        state.generation += 1
        fetchStateByRepo[repoPath] = state
        let gen = state.generation

        Task { [weak self] in
            await self?.performRepoFetch(repoPath: repoPath, fetchGeneration: gen)
        }
        return true
    }

    private struct WorktreeView {
        let path: String
        let branch: String
        let hasRemote: Bool
    }

    /// Worktrees for `repoPath` from the current model. Re-read at
    /// apply time (not snapshotted at dispatch) so a
    /// `branchDidChange` between dispatch and result lands on the
    /// new branch rather than writing the old branch's stale PR
    /// back into the worktree's cache. @spec PR-8.18
    private func currentWorktreeViews(repoPath: String) -> [WorktreeView] {
        guard let repo = getRepos().first(where: { $0.path == repoPath }) else { return [] }
        return repo.worktrees
            .filter { $0.state.hasOnDiskWorktree }
            .map { wt in
                WorktreeView(
                    path: wt.path,
                    branch: wt.branch,
                    hasRemote: hasRemoteBranch(repoPath: repoPath, branch: wt.branch)
                )
            }
    }

    private func performRepoFetch(repoPath: String, fetchGeneration: Int) async {
        defer {
            if fetchStateByRepo[repoPath]?.generation == fetchGeneration {
                fetchStateByRepo[repoPath]?.inFlightSince = nil
            }
        }

        let origin: HostingOrigin?
        if let cached = hostByRepo[repoPath] {
            origin = cached
        } else {
            do {
                let detected = try await detectHost(repoPath)
                origin = detected
                hostByRepo[repoPath] = detected
            } catch {
                logger.debug("host detect failed for \(repoPath): \(String(describing: error))")
                origin = nil
            }
        }
        if fetchStateByRepo[repoPath]?.generation != fetchGeneration { return }
        guard let origin, origin.provider != .unsupported,
              let fetcher = fetcherFor(origin.provider) else {
            applySnapshot(RepoPRSnapshot(prsByBranch: [:]), repoPath: repoPath, origin: nil)
            fetchStateByRepo[repoPath]?.lastFetch = Date()
            return
        }

        let branchesOfInterest = Set(
            currentWorktreeViews(repoPath: repoPath)
                .filter { Self.isFetchableBranch($0.branch) && $0.hasRemote }
                .map(\.branch)
        )

        let snapshot: RepoPRSnapshot
        do {
            snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: branchesOfInterest)
        } catch {
            if fetchStateByRepo[repoPath]?.generation != fetchGeneration { return }
            logger.info("PR fetch failed for repo \(repoPath): \(String(describing: error))")
            // PR-7.10: per-worktree `infos` stays untouched on
            // failure. Next successful fetch reconciles.
            fetchStateByRepo[repoPath]?.failureStreak += 1
            fetchStateByRepo[repoPath]?.lastFetch = Date()
            return
        }

        if fetchStateByRepo[repoPath]?.generation != fetchGeneration { return }
        fetchStateByRepo[repoPath]?.lastFetch = Date()
        fetchStateByRepo[repoPath]?.failureStreak = 0

        applySnapshot(snapshot, repoPath: repoPath, origin: origin)
    }

    /// Distributes `snapshot` to each worktree of `repoPath`. When
    /// `origin` is nil the snapshot is treated as authoritatively
    /// empty (unsupported host) — every fetchable, pushed worktree
    /// is marked absent.
    private func applySnapshot(
        _ snapshot: RepoPRSnapshot,
        repoPath: String,
        origin: HostingOrigin?
    ) {
        for wt in currentWorktreeViews(repoPath: repoPath) {
            if !Self.isFetchableBranch(wt.branch) {
                clear(worktreePath: wt.path)
                continue
            }
            if !wt.hasRemote {
                markLocallyUnpushed(wt.path)
                continue
            }
            guard let pr = snapshot.prsByBranch[wt.branch] else {
                if infos[wt.path] != nil {
                    infos.removeValue(forKey: wt.path)
                }
                markAbsent(wt.path)
                continue
            }
            let prev = infos[wt.path]
            let justMerged = pr.state == .merged
                && (prev?.state != .merged || prev?.number != pr.number)
            if let origin {
                detectAndFireTransitions(
                    worktreePath: wt.path,
                    previous: prev,
                    current: pr,
                    origin: origin
                )
            }
            if prev != pr {
                infos[wt.path] = pr
            }
            if absent.contains(wt.path) {
                absent.remove(wt.path)
            }
            if justMerged, let onPRMerged {
                onPRMerged(wt.path, pr.number)
            }
        }
    }

    private func markAbsent(_ worktreePath: String) {
        // Set.insert is idempotent; the contains-check is only
        // here so an idempotent poll doesn't fire `@Observable`
        // notifications and re-render every SidebarView row.
        if !absent.contains(worktreePath) {
            absent.insert(worktreePath)
        }
    }

    private func markLocallyUnpushed(_ worktreePath: String) {
        if infos[worktreePath] != nil {
            infos.removeValue(forKey: worktreePath)
        }
        if absent.contains(worktreePath) {
            absent.remove(worktreePath)
        }
    }

    private func hasRemoteBranch(repoPath: String, branch: String) -> Bool {
        guard let remoteBranchStore else { return true }
        return remoteBranchStore.hasRemote(repoPath: repoPath, branch: branch)
    }

    private func detectAndFireTransitions(
        worktreePath: String,
        previous: PRInfo?,
        current: PRInfo,
        origin: HostingOrigin
    ) {
        guard let onTransition, let previous else { return }

        let stateChanged = previous.state != current.state
        let checksChanged = previous.checks != current.checks
        let mergeableChanged = previous.mergeable != current.mergeable
        guard stateChanged || checksChanged || mergeableChanged else { return }

        let common: [String: String] = [
            "pr_number": String(current.number),
            "pr_url": current.url.absoluteString,
            "provider": origin.provider.rawValue,
            "repo": origin.slug,
            "worktree": worktreePath,
        ]

        if stateChanged {
            var attrs = common
            attrs["from"] = previous.state.rawValue
            attrs["to"] = current.state.rawValue
            attrs["pr_title"] = current.title
            let routable: RoutableEvent = (current.state == .merged) ? .prMerged : .prStateChanged
            onTransition(routable, worktreePath, attrs)
        }
        if checksChanged {
            var attrs = common
            attrs["from"] = previous.checks.rawValue
            attrs["to"] = current.checks.rawValue
            onTransition(.ciConclusionChanged, worktreePath, attrs)
        }
        if mergeableChanged {
            var attrs = common
            attrs["from"] = previous.mergeable.rawValue
            attrs["to"] = current.mergeable.rawValue
            onTransition(.mergabilityChanged, worktreePath, attrs)
        }
    }

    /// Test seam.
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

    /// Branches wrapped in parens (`(detached)`, `(bare)`,
    /// `(unknown)`, `(unborn)`) are git sentinels — none of them
    /// correspond to a real `refs/heads/` value, so they can't
    /// appear in any PR snapshot.
    public nonisolated static func isFetchableBranch(_ branch: String) -> Bool {
        if branch.hasPrefix("(") && branch.hasSuffix(")") { return false }
        return !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Time-bound cap on the per-repo `inFlight` guard. A normal
    /// `gh pr list` resolves in under a few seconds; anything
    /// in-flight longer is assumed abandoned (stuck subprocess,
    /// rate-limit back-off, auth retry loop) and superseded by the
    /// next dispatch.
    nonisolated static func refreshCadence() -> Duration {
        .seconds(30)
    }

    /// Per-repo polling cadence. Single base value (5s) matches
    /// the ticker interval — every tick attempts a fetch unless an
    /// earlier one is still in-flight or just completed. Failures
    /// back off exponentially up to 60s so a misconfigured `gh`
    /// doesn't hammer the network on every tick. @spec PR-8.19
    nonisolated static func cadenceFor(failureStreak: Int) -> Duration {
        ExponentialBackoff.scale(
            base: .seconds(5),
            streak: failureStreak,
            cap: .seconds(60)
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
        pruneStaleRepoState(currentRepoPaths: Set(repos.map(\.path)))
        for repo in repos where repo.worktrees.contains(where: { $0.state.hasOnDiskWorktree }) {
            dispatchRepoFetch(repoPath: repo.path, force: false)
        }
    }

    /// Drop bookkeeping for repos no longer in the model. Without
    /// this, `fetchStateByRepo` and `hostByRepo` grow unbounded as
    /// the user adds and removes repos over a long-running
    /// session. @spec PR-8.22
    private func pruneStaleRepoState(currentRepoPaths: Set<String>) {
        for repoPath in fetchStateByRepo.keys where !currentRepoPaths.contains(repoPath) {
            fetchStateByRepo.removeValue(forKey: repoPath)
        }
        for repoPath in hostByRepo.keys where !currentRepoPaths.contains(repoPath) {
            hostByRepo.removeValue(forKey: repoPath)
        }
    }
}
