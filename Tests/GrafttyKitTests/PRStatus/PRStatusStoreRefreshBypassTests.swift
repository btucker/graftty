import Testing
import Foundation
@testable import GrafttyKit

/// `PR-7.12` ("sidebar selection refreshes PR status") depends on
/// `PRStatusStore.refresh` short-circuiting the `PR-7.2` cadence-backoff
/// gate the background ticker applies. If someone later adds a cadence
/// check inside `refresh` to "save gh calls", selection no longer
/// self-heals a stale badge — the exact user-visible regression that
/// motivated PR-7.12 in the first place. Pin the invariant here.
@Suite("PRStatusStore — refresh bypasses cadence (PR-7.12)")
struct PRStatusStoreRefreshBypassTests {

    actor CountingFetcher: PRFetcher {
        private(set) var invocations = 0
        private let response: PRInfo?
        init(response: PRInfo?) { self.response = response }
        func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo? {
            invocations += 1
            return response
        }
    }

    private static let origin = HostingOrigin(
        provider: .github, host: "github.com", owner: "foo", repo: "bar"
    )

    private static func pr(number: Int, state: PRInfo.State) -> PRInfo {
        PRInfo(
            number: number,
            title: "PR\(number)",
            url: URL(string: "https://github.com/foo/bar/pull/\(number)")!,
            state: state,
            checks: .none,
            fetchedAt: Date()
        )
    }

    @MainActor
    @Test func backToBackRefreshCallsBothHitTheFetcher() async throws {
        let fetcher = CountingFetcher(response: Self.pr(number: 42, state: .open))
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in Self.origin }
        )

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        for _ in 0..<100 {
            if await fetcher.invocations >= 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await fetcher.invocations == 1, "first refresh should fetch")

        // Second refresh immediately after — no time for cadence to expire.
        // The background poll would gate this out; refresh must not.
        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        for _ in 0..<100 {
            if await fetcher.invocations >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(
            await fetcher.invocations == 2,
            "refresh must bypass the PR-7.2 cadence gate — sidebar selection (PR-7.12) depends on this"
        )
    }
}
