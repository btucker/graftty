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
    @ObservationIgnored private var hostByRepo: [String: HostingOrigin?] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var lastFetch: [String: Date] = [:]
    @ObservationIgnored private var failureStreak: [String: Int] = [:]
    @ObservationIgnored private var ticker: PollingTickerLike?
    @ObservationIgnored private var getRepos: @MainActor () -> [RepoEntry] = { [] }
    @ObservationIgnored private let logger = Logger(subsystem: "com.btucker.espalier", category: "PRStatusStore")

    public init(
        executor: CLIExecutor = CLIRunner(),
        fetcherFor: ((HostingProvider) -> PRFetcher?)? = nil
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
        infos.removeValue(forKey: worktreePath)
        absent.remove(worktreePath)
        lastFetch.removeValue(forKey: worktreePath)
        failureStreak.removeValue(forKey: worktreePath)
    }

    // MARK: - Fetch

    private func performFetch(worktreePath: String, repoPath: String, branch: String) async {
        defer { inFlight.remove(worktreePath) }

        // Resolve host (cached per repo).
        let origin: HostingOrigin?
        if let cached = hostByRepo[repoPath] {
            origin = cached
        } else {
            origin = (try? await GitOriginHost.detect(repoPath: repoPath)) ?? nil
            hostByRepo[repoPath] = origin
        }
        guard let origin, origin.provider != .unsupported,
              let fetcher = fetcherFor(origin.provider) else {
            absent.insert(worktreePath)
            lastFetch[worktreePath] = Date()
            return
        }

        do {
            let pr = try await fetcher.fetch(origin: origin, branch: branch)
            lastFetch[worktreePath] = Date()
            failureStreak[worktreePath] = 0
            if let pr {
                infos[worktreePath] = pr
                absent.remove(worktreePath)
            } else {
                infos.removeValue(forKey: worktreePath)
                absent.insert(worktreePath)
            }
        } catch {
            logger.info("PR fetch failed for \(worktreePath): \(String(describing: error))")
            failureStreak[worktreePath, default: 0] += 1
            lastFetch[worktreePath] = Date()
            infos.removeValue(forKey: worktreePath)
        }
    }
}
