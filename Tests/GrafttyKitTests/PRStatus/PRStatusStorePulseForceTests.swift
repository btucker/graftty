import Testing
import GrafttyProtocol
import Foundation
@testable import GrafttyKit

/// A `pulse()` is an explicit "refresh now" signal — window focus, the
/// add-worktree BranchPicker opening, or a newly-pushed remote branch.
/// The call sites promise fresh data "even if the polling cadence is in
/// a long-backoff", so a pulse must force the next tick past the
/// per-repo cadence gate (60s base, up to 300s during a rate-limit
/// backoff). A pulse that only woke the ticker into a cadence-gated
/// tick would no-op for up to five minutes, silently rendering stale
/// PR data.
@Suite("PRStatusStore — pulse forces past cadence", .serialized)
struct PRStatusStorePulseForceTests {

    actor CountingFetcher: PRFetcher {
        private(set) var invocations = 0
        private(set) var fetchedRepos: Set<String> = []
        func fetch(
            origin: HostingOrigin,
            branchesOfInterest: Set<String>
        ) async throws -> RepoPRSnapshot {
            invocations += 1
            fetchedRepos.insert(origin.repo)
            return RepoPRSnapshot(prsByBranch: [:])
        }
    }

    private static let origin = HostingOrigin(
        provider: .github, host: "github.com", owner: "o", repo: "r"
    )

    @MainActor
    @Test("@spec PR-8.25: When a pulse is requested, the application shall force the next poll past the per-repo cadence gate so an explicit refresh signal (window focus, add-worktree picker, newly-pushed branch) fetches fresh PR data even while the background cadence is in a long backoff.")
    func pulseForcesFetchPastCadenceGate() async throws {
        let fetcher = CountingFetcher()
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in Self.origin }
        )
        let ticker = ManualTicker()
        let repo = RepoEntry(
            path: "/repo",
            displayName: "repo",
            worktrees: [WorktreeEntry(path: "/repo/wt", branch: "feature", state: .running)]
        )
        store.start(ticker: ticker, getRepos: { [repo] })
        defer { store.stop() }

        // First tick fetches (no prior `lastFetch`) and completes,
        // stamping `lastFetch` to "now".
        await ticker.fire()
        for _ in 0..<200 {
            if await fetcher.invocations >= 1 && !store.isInFlightForTesting("/repo") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await fetcher.invocations == 1)

        // A plain tick now is suppressed by the 60s cadence gate.
        await ticker.fire()
        try await Task.sleep(for: .milliseconds(50))
        #expect(
            await fetcher.invocations == 1,
            "a non-forced tick within the cadence window must be gated"
        )

        // `pulse()` must force the next tick past that gate.
        store.pulse()
        await ticker.fire()
        for _ in 0..<200 {
            if await fetcher.invocations >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(
            await fetcher.invocations == 2,
            "pulse must force a fetch past the cadence gate (PR-8.25)"
        )
    }

    @MainActor
    @Test("@spec PR-8.28: When a remote-branch snapshot gains refs for one repository, the application shall force PR polling only for that repository rather than bypass the cadence gate for every repository in the workspace.")
    func repoScopedPulseFetchesOnlyTheChangedRepository() async throws {
        let fetcher = CountingFetcher()
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { repoPath in
                HostingOrigin(
                    provider: .github,
                    host: "github.com",
                    owner: "o",
                    repo: String(repoPath.dropFirst())
                )
            }
        )
        let ticker = ManualTicker()
        let repos = ["a", "b", "c"].map { name in
            RepoEntry(
                path: "/\(name)",
                displayName: name,
                worktrees: [
                    WorktreeEntry(
                        path: "/\(name)/wt",
                        branch: "feature",
                        state: .running
                    ),
                ]
            )
        }
        store.start(ticker: ticker, getRepos: { repos })
        defer { store.stop() }

        for repo in repos {
            store.seedLastFetchForTesting(Date(), forRepo: repo.path)
        }
        RemoteBranchPRRefreshRouter.route(
            repo: repos[1],
            oldBranches: [],
            newBranches: ["feature"],
            clear: { store.clear(worktreePath: $0) },
            pulseRepo: { store.pulse(repoPath: $0) }
        )
        await ticker.fire()
        for _ in 0..<200 {
            if await fetcher.invocations == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(await fetcher.invocations == 1)
        #expect(await fetcher.fetchedRepos == ["b"])
    }

    @MainActor
    @Test func repeatedRepoScopedPulsesDoNotStarveOrdinaryPolling() async throws {
        let fetcher = CountingFetcher()
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { repoPath in
                HostingOrigin(
                    provider: .github,
                    host: "github.com",
                    owner: "o",
                    repo: String(repoPath.dropFirst())
                )
            }
        )
        let ticker = ManualTicker()
        let repos = (0..<8).map { index in
            RepoEntry(
                path: "/repo-\(index)",
                displayName: "repo-\(index)",
                worktrees: [
                    WorktreeEntry(
                        path: "/repo-\(index)/wt",
                        branch: "feature",
                        state: .running
                    ),
                ]
            )
        }
        store.start(ticker: ticker, getRepos: { repos })
        defer { store.stop() }

        for expectedInvocationCount in [4, 8, 10] {
            store.pulse(repoPath: repos[0].path)
            await ticker.fire()
            for _ in 0..<200 {
                if await fetcher.invocations >= expectedInvocationCount { break }
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        #expect(await fetcher.fetchedRepos == Set(repos.map(\.displayName)))
    }
}
