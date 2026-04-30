import Testing
import Foundation
@testable import GrafttyKit

/// Regression for the polling loop itself getting stuck behind a hung
/// host CLI call. `PR-7.13` lets later dispatches supersede old in-flight
/// work, but that only helps if the ticker can keep ticking; awaiting the
/// whole tick batch means one stuck `gh`/`glab` subprocess freezes the
/// background poller until a separate user-triggered `refresh()` happens.
@Suite("""
PRStatusStore polling tick liveness

@spec PR-7.14: The PR polling tick shall dispatch eligible per-worktree fetches and return without awaiting those fetch Tasks. The ticker loop itself must remain live even if a `gh` / `glab` subprocess hangs, otherwise `PR-7.13`'s abandoned-in-flight recovery never gets a later polling tick on which to supersede the stuck fetch. A hung fetch may occupy that worktree's `inFlight` slot until the `PR-7.13` 30-second inFlight cap elapses, but it must not stop unrelated worktrees from polling or require the user to click the sidebar to trigger the separate on-demand refresh path.
""")
struct PRStatusStorePollTickHangTests {

    @MainActor
    @Test func tickReturnsWithoutWaitingForHungFetch() async throws {
        let ticker = CapturingTicker()
        let hang = AsyncStream<Void>.makeStream()
        let fetcher = HangingPRFetcher(stream: hang.stream)
        let origin = HostingOrigin(
            provider: .github, host: "github.com", owner: "foo", repo: "bar"
        )
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in origin }
        )
        let repo = RepoEntry(
            path: "/repo",
            displayName: "repo",
            worktrees: [WorktreeEntry(path: "/repo/wt", branch: "feature")]
        )

        store.start(ticker: ticker, getRepos: { [repo] })
        defer {
            hang.continuation.finish()
            store.stop()
        }

        let returned = await returnsWithin(.milliseconds(200)) {
            await ticker.fire()
        }

        #expect(
            returned,
            "poll ticks must schedule PR fetches and return; a hung fetch must not stop future polling"
        )
    }

    private func returnsWithin(
        _ duration: Duration,
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: duration)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

@MainActor
private final class CapturingTicker: PollingTickerLike {
    private var onTick: (@MainActor () async -> Void)?

    func start(onTick: @MainActor @escaping () async -> Void) {
        self.onTick = onTick
    }

    func stop() {
        onTick = nil
    }

    func pulse() {}

    func fire() async {
        await onTick?()
    }
}

private actor HangingPRFetcher: PRFetcher {
    private let stream: AsyncStream<Void>

    init(stream: AsyncStream<Void>) {
        self.stream = stream
    }

    func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo? {
        for await _ in stream {}
        return nil
    }
}
