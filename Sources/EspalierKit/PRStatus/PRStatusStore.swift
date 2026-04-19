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
    @ObservationIgnored private let detectHost: @Sendable (String) async -> HostingOrigin?
    @ObservationIgnored private var hostByRepo: [String: HostingOrigin?] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var lastFetch: [String: Date] = [:]
    @ObservationIgnored private var failureStreak: [String: Int] = [:]
    /// Per-path generation counter. Bumped by `clear(worktreePath:)` so
    /// that an in-flight `performFetch` can detect when its result has
    /// been invalidated and bail out before writing stale data back into
    /// `infos`/`absent`.
    @ObservationIgnored private var generation: [String: Int] = [:]
    @ObservationIgnored private var ticker: PollingTickerLike?
    @ObservationIgnored private var getRepos: @MainActor () -> [RepoEntry] = { [] }
    @ObservationIgnored private let logger = Logger(subsystem: "com.btucker.espalier", category: "PRStatusStore")

    public init(
        executor: CLIExecutor = CLIRunner(),
        fetcherFor: ((HostingProvider) -> PRFetcher?)? = nil,
        detectHost: (@Sendable (String) async -> HostingOrigin?)? = nil
    ) {
        self.executor = executor
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
                (try? await GitOriginHost.detect(repoPath: repoPath)) ?? nil
            }
        }
    }

    /// Force a fetch for one worktree, regardless of cadence. Skips if already
    /// in flight.
    public func refresh(worktreePath: String, repoPath: String, branch: String) {
        guard !inFlight.contains(worktreePath) else { return }
        inFlight.insert(worktreePath)

        Task { [weak self] in
            await self?.performFetch(
                worktreePath: worktreePath,
                repoPath: repoPath,
                branch: branch
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
        // Release the refresh gate so a subsequent `refresh` isn't
        // silently no-op'd while the prior Task drains. The Task's own
        // `defer { inFlight.remove(...) }` is still safe (Set.remove
        // with an absent key is a no-op).
        inFlight.remove(worktreePath)
        // Bump the generation so any in-flight fetch's late write
        // (after its await resumes) can detect it's been invalidated
        // and discard its result.
        generation[worktreePath, default: 0] += 1
    }

    // Test hooks — not used in production. Kept internal so they're
    // reachable from EspalierKitTests without widening the public API.
    func generationForTesting(_ worktreePath: String) -> Int {
        generation[worktreePath, default: 0]
    }

    func isInFlightForTesting(_ worktreePath: String) -> Bool {
        inFlight.contains(worktreePath)
    }

    func beginInFlightForTesting(_ worktreePath: String) {
        inFlight.insert(worktreePath)
    }

    /// Notify the store that a worktree's branch has changed. Drops the
    /// cached PR info synchronously so the UI doesn't keep showing the
    /// previous branch's PR through the gh-fetch in-flight window, then
    /// schedules a fresh fetch for the new branch — bypassing the
    /// `inFlight` guard so a concurrent polling-cycle fetch doesn't
    /// suppress the re-resolve.
    public func branchDidChange(worktreePath: String, repoPath: String, branch: String) {
        clear(worktreePath: worktreePath)
        inFlight.remove(worktreePath)
        refresh(worktreePath: worktreePath, repoPath: repoPath, branch: branch)
    }

    // MARK: - Fetch

    private func performFetch(worktreePath: String, repoPath: String, branch: String) async {
        defer { inFlight.remove(worktreePath) }

        // Snapshot the generation we started under. `clear()` bumps it;
        // if it differs after any `await`, this fetch's result is stale
        // — Andy already expressed "forget this worktree" — and we bail
        // before writing back to `infos`/`absent`.
        let fetchGeneration = generation[worktreePath, default: 0]

        let origin: HostingOrigin?
        if let cached = hostByRepo[repoPath] {
            origin = cached
        } else {
            origin = await detectHost(repoPath)
            hostByRepo[repoPath] = origin
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
                if infos[worktreePath] != pr {
                    infos[worktreePath] = pr
                }
                if absent.contains(worktreePath) {
                    absent.remove(worktreePath)
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
            if infos[worktreePath] != nil {
                infos.removeValue(forKey: worktreePath)
            }
        }
    }

    private func markAbsent(_ worktreePath: String) {
        if !absent.contains(worktreePath) {
            absent.insert(worktreePath)
        }
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

    nonisolated static func cadenceFor(
        info: PRInfo?,
        isAbsent: Bool,
        failureStreak: Int
    ) -> Duration {
        let base: Duration
        if let info {
            switch (info.state, info.checks) {
            case (.open, .pending): base = .seconds(25)
            case (.open, _):        base = .seconds(5 * 60)
            case (.merged, _):      base = .seconds(15 * 60)
            }
        } else if isAbsent {
            base = .seconds(15 * 60)
        } else {
            base = .zero
        }
        // Floor the unknown-state base at 60s so a failing fetch has
        // something to multiply — otherwise the poller retries every tick
        // against a broken CLI (e.g. `gh` not installed).
        return ExponentialBackoff.scale(
            base: base,
            streak: failureStreak,
            cap: .seconds(30 * 60),
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

        struct Candidate { let path, repoPath, branch: String }
        var candidates: [Candidate] = []

        for repo in repos {
            // If host resolution already concluded "no origin" or "unsupported",
            // skip. Uncached repos fall through — performFetch resolves on first run.
            if let cached = hostByRepo[repo.path],
               cached == nil || cached?.provider == .unsupported {
                continue
            }
            for wt in repo.worktrees where wt.state != .stale {
                if inFlight.contains(wt.path) { continue }
                if !Self.isFetchableBranch(wt.branch) { continue }
                let interval = cadence(for: wt.path)
                let last = lastFetch[wt.path]
                if let last, now.timeIntervalSince(last) < Double(interval.components.seconds) {
                    continue
                }
                candidates.append(Candidate(path: wt.path, repoPath: repo.path, branch: wt.branch))
            }
        }

        let maxParallel = 4
        await withTaskGroup(of: Void.self) { group in
            var inflight = 0
            for c in candidates {
                if inflight >= maxParallel {
                    await group.next()
                    inflight -= 1
                }
                inFlight.insert(c.path)
                group.addTask { [weak self] in
                    await self?.performFetch(
                        worktreePath: c.path,
                        repoPath: c.repoPath,
                        branch: c.branch
                    )
                }
                inflight += 1
            }
        }
    }
}
