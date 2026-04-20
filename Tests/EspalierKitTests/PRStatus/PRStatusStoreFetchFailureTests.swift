import Testing
import Foundation
@testable import EspalierKit

/// When a PR fetch fails (network hiccup, gh auth expired, rate
/// limit), the cached PR info must stay in place rather than being
/// wiped. A transient failure shouldn't erase the user-visible badge
/// — gh is the only channel, and dropping cached info on every failed
/// poll makes the breadcrumb / sidebar badge flicker in and out while
/// the backoff (`PR-7.2`) waits to retry. The right behaviour is to
/// keep the last-known state and let the next successful fetch either
/// confirm or update it.
@Suite("PRStatusStore — fetch-failure cache preservation")
struct PRStatusStoreFetchFailureTests {

    enum StubError: Error { case failed }

    /// Scripted fetcher whose response can be flipped to "throw" after
    /// the first success, so the test can observe what happens to the
    /// cached info across one failure without also having to model
    /// the whole retry cadence.
    actor FlipFetcher: PRFetcher {
        private var mode: Mode
        enum Mode { case ok(PRInfo?), throwing }
        init(initial: PRInfo?) { self.mode = .ok(initial) }
        func flipToThrowing() { mode = .throwing }
        func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo? {
            switch mode {
            case .ok(let info): return info
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
        let fetcher = FlipFetcher(initial: Self.pr(number: 42))
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in Self.origin }
        )

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        for _ in 0..<100 {
            if store.infos["/wt"]?.number == 42 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.infos["/wt"]?.number == 42, "first fetch should publish PR#42")

        // Flip the fetcher to throwing and trigger another refresh.
        await fetcher.flipToThrowing()
        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")

        // Wait long enough for the failed fetch to land.
        try await Task.sleep(for: .milliseconds(120))

        #expect(
            store.infos["/wt"]?.number == 42,
            "transient fetch failure must not drop cached PR info"
        )
    }
}
