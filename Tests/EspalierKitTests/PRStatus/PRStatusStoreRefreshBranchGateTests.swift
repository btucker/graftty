import Testing
import Foundation
@testable import EspalierKit

/// The polling loop already skips worktrees whose `branch` is a git
/// sentinel like `(detached)` (see PRStatusStore+Poller's pick loop).
/// The on-demand callers — MainWindow's select-worktree refresh and
/// `branchDidChange` from a HEAD-change event — did not, meaning a
/// detached-HEAD worktree still fired two wasted `gh pr list` calls
/// per selection / HEAD change. PR-7.5.
@Suite("PRStatusStore — refresh fetchable-branch gate")
struct PRStatusStoreRefreshBranchGateTests {

    /// Counts `fetch` calls so we can verify the gate is respected.
    final class CountingFetcher: PRFetcher, @unchecked Sendable {
        var fetchCount: Int = 0
        func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo? {
            fetchCount += 1
            return nil
        }
    }

    @MainActor
    @Test func refreshWithSentinelBranchIsNoOp() async {
        let fetcher = CountingFetcher()
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in HostingOrigin(provider: .github, host: "github.com", owner: "o", repo: "r") }
        )

        store.refresh(worktreePath: "/wt", repoPath: "/r", branch: "(detached)")
        // Give any accidentally-spawned Task a chance to run to completion.
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(!store.isInFlightForTesting("/wt"), "sentinel branch must not enter inFlight")
        #expect(fetcher.fetchCount == 0, "no `gh` invocations for sentinel branches")
    }

    @MainActor
    @Test func branchDidChangeToSentinelDoesNotFetch() async {
        let fetcher = CountingFetcher()
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in HostingOrigin(provider: .github, host: "github.com", owner: "o", repo: "r") }
        )

        // Precondition: the worktree already had some cached state.
        store.beginInFlightForTesting("/wt")
        #expect(store.isInFlightForTesting("/wt"))

        store.branchDidChange(worktreePath: "/wt", repoPath: "/r", branch: "(detached)")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(!store.isInFlightForTesting("/wt"), "branchDidChange → sentinel must release inFlight")
        #expect(fetcher.fetchCount == 0, "branchDidChange → sentinel must not fetch")
    }

    @MainActor
    @Test func refreshWithRealBranchStillFetches() async {
        let fetcher = CountingFetcher()
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in HostingOrigin(provider: .github, host: "github.com", owner: "o", repo: "r") }
        )

        store.refresh(worktreePath: "/wt", repoPath: "/r", branch: "main")
        // Wait for the spawned Task to run to completion.
        for _ in 0..<20 {
            if fetcher.fetchCount > 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(fetcher.fetchCount == 1, "real branches are still fetched")
    }
}
