import Testing
import Foundation
@testable import GrafttyKit

/// `PR-7.12` ("sidebar selection refreshes PR status") depends on
/// `PRStatusStore.refresh` short-circuiting the cadence-backoff
/// gate the background ticker applies. If someone later adds a
/// cadence check inside `refresh` to "save gh calls", selection
/// no longer self-heals a stale badge — pin the invariant here.
@Suite("""
PRStatusStore — refresh bypasses cadence

@spec PR-7.12: When the user selects a worktree in the sidebar, the application shall call `PRStatusStore.refresh`, bypassing the per-repo polling cadence. Even with the 60-second cap, a worst-case 60-second wait for a freshly-merged PR to appear in the breadcrumb is longer than the click-to-feedback loop a user expects on selection. Sidebar selection is a strong "user cares about this worktree now" signal, and the existing `refresh` path already short-circuits cadence and resets `failureStreak` on success — wiring it to selection closes the stale-UI escape hatch without any new mechanism.
""")
struct PRStatusStoreRefreshBypassTests {

    actor CountingFetcher: PRFetcher {
        private(set) var invocations = 0
        private let response: RepoPRSnapshot
        init(response: RepoPRSnapshot) { self.response = response }
        func fetch(
            origin: HostingOrigin,
            branchesOfInterest: Set<String>
        ) async throws -> RepoPRSnapshot {
            invocations += 1
            return response
        }
    }

    private static let origin = HostingOrigin(
        provider: .github, host: "github.com", owner: "foo", repo: "bar"
    )

    private static func snapshot(number: Int, state: PRInfo.State) -> RepoPRSnapshot {
        RepoPRSnapshot(prsByBranch: [
            "feat": PRInfo(
                number: number,
                title: "PR\(number)",
                url: URL(string: "https://github.com/foo/bar/pull/\(number)")!,
                state: state,
                checks: .none,
                fetchedAt: Date()
            )
        ])
    }

    @MainActor
    @Test func backToBackRefreshesBothFetchOnceTheInFlightSlotReleases() async throws {
        let fetcher = CountingFetcher(response: Self.snapshot(number: 42, state: .open))
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in Self.origin }
        )

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        for _ in 0..<200 {
            if await fetcher.invocations >= 1 && !store.isInFlightForTesting("/repo") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await fetcher.invocations == 1, "first refresh should fetch")
        #expect(!store.isInFlightForTesting("/repo"))

        // Second refresh immediately after, well within the 5s
        // cadence window. The background poll would gate this out;
        // refresh must not.
        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        for _ in 0..<200 {
            if await fetcher.invocations >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(
            await fetcher.invocations == 2,
            "refresh must bypass the per-repo cadence gate — sidebar selection (PR-7.12) depends on this"
        )
    }
}
