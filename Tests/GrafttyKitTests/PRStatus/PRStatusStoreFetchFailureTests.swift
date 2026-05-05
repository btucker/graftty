import Testing
import Foundation
@testable import GrafttyKit

/// When a PR fetch fails (network hiccup, gh auth expired, rate
/// limit), the cached PR info must stay in place rather than
/// being wiped. A transient failure shouldn't erase the
/// user-visible badge — gh is the only channel, and dropping
/// cached info on every failed poll makes the breadcrumb /
/// sidebar badge flicker in and out while the per-repo backoff
/// waits to retry. Keep the last-known state and let the next
/// successful fetch either confirm or update it.
@Suite("""
PRStatusStore — fetch-failure cache preservation

@spec PR-7.10: When a PR fetch fails (network error, rate limit, expired `gh` auth), the application shall preserve every worktree's last-known `PRInfo` cache entry for that repo rather than removing them. A transient failure is not evidence that any PR stopped existing, and dropping cached info on every failed poll makes the sidebar badge and breadcrumb PR button flicker in and out while the per-repo backoff waits to retry. The next successful fetch either confirms the cached state or updates it.
""")
struct PRStatusStoreFetchFailureTests {

    enum StubError: Error { case failed }

    /// Scripted fetcher whose response flips to "throw" after the
    /// first success, so the test can observe what happens to
    /// cached info across one failure without modeling the retry
    /// cadence.
    actor FlipFetcher: PRFetcher {
        private var mode: Mode
        enum Mode { case ok(RepoPRSnapshot), throwing }
        init(initial: RepoPRSnapshot) { self.mode = .ok(initial) }
        func flipToThrowing() { mode = .throwing }
        func fetch(
            origin: HostingOrigin,
            branchesOfInterest: Set<String>
        ) async throws -> RepoPRSnapshot {
            switch mode {
            case .ok(let snap): return snap
            case .throwing: throw StubError.failed
            }
        }
    }

    private static let origin = HostingOrigin(
        provider: .github, host: "github.com", owner: "foo", repo: "bar"
    )

    private static func pr(number: Int) -> PRInfo {
        PRInfo(
            number: number,
            title: "PR\(number)",
            url: URL(string: "https://github.com/foo/bar/pull/\(number)")!,
            state: .open,
            checks: .none,
            fetchedAt: Date()
        )
    }

    @MainActor
    @Test func fetchFailureKeepsLastKnownInfo() async throws {
        let initial = RepoPRSnapshot(prsByBranch: ["feat": Self.pr(number: 42)])
        let fetcher = FlipFetcher(initial: initial)
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in Self.origin }
        )
        let ticker = ManualTicker()
        let repo = RepoEntry(
            path: "/repo",
            displayName: "repo",
            worktrees: [WorktreeEntry(path: "/wt", branch: "feat", state: .running)]
        )
        store.start(ticker: ticker, getRepos: { [repo] })
        defer { store.stop() }

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        for _ in 0..<100 {
            if store.infos["/wt"]?.number == 42 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.infos["/wt"]?.number == 42, "first fetch should publish PR#42")

        await fetcher.flipToThrowing()
        // Step the in-flight clock past `refreshCadence` so the
        // next refresh isn't suppressed by the still-recorded slot.
        store.seedInFlightSinceForTesting(
            Date().addingTimeInterval(-3600),
            forRepo: "/repo"
        )
        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")

        try await Task.sleep(for: .milliseconds(120))

        #expect(
            store.infos["/wt"]?.number == 42,
            "transient fetch failure must not drop cached PR info"
        )
    }
}

