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

        let origin: HostingOrigin?
        if let cached = hostByRepo[repoPath] {
            origin = cached
        } else {
            origin = await detectHost(repoPath)
            hostByRepo[repoPath] = origin
        }
        guard let origin, origin.provider != .unsupported,
              let fetcher = fetcherFor(origin.provider) else {
            markAbsent(worktreePath)
            lastFetch[worktreePath] = Date()
            return
        }

        do {
            let pr = try await fetcher.fetch(origin: origin, branch: branch)
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
