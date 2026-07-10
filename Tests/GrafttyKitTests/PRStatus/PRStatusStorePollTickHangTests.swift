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

@spec PR-7.14: The PR polling tick shall dispatch eligible per-repo fetches and return without awaiting those fetch Tasks. The ticker loop itself must remain live even if a `gh` / `glab` subprocess hangs, otherwise `PR-7.13`'s abandoned-in-flight recovery never gets a later polling tick on which to supersede the stuck fetch. A hung fetch may occupy that repo's `inFlight` slot until the `PR-7.13` 30-second inFlight cap elapses, but it must not stop unrelated repos from polling or require the user to click the sidebar to trigger the separate on-demand refresh path.
""")
struct PRStatusStorePollTickHangTests {

    // The 1-minute limit is a coarse backstop for the *regression* case only
    // (a tick that awaits the fetch never returns); it is not a latency
    // threshold. The pass path returns immediately regardless of load.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func tickReturnsWithoutWaitingForHungFetch() async throws {
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

        // The fetcher hangs forever (until the defer's `finish()`), so if the
        // tick awaited it this call would never return. Awaiting `fire()` to
        // completion — rather than racing it against a wall-clock deadline —
        // proves the tick dispatched-and-returned: a real regression hangs here
        // and the time limit fails the test, while correct behavior returns at
        // once. A deadline race instead false-failed under the shared-MainActor
        // contention of parallel suites (a busy MainActor delays even the hop to
        // this instant tick — the PollingHeart starvation artifact).
        await ticker.fire()
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

    func fetch(
        origin: HostingOrigin,
        branchesOfInterest: Set<String>
    ) async throws -> RepoPRSnapshot {
        for await _ in stream {}
        return RepoPRSnapshot(prsByBranch: [:])
    }
}
