import Testing
import Foundation
@testable import GrafttyKit

/// Reproduces the "PR status only updates when I click between
/// worktrees" symptom at the in-flight gate: a `gh pr list`
/// subprocess hangs, the per-repo `inFlight` guard keeps the
/// repo as "in flight" forever, and every subsequent background
/// poll plus every user-triggered `refresh()` short-circuits at
/// the in-flight gate. The fix is the time-bounded gate
/// (`refreshCadence`): a dispatch older than the cap is treated
/// as abandoned and superseded; the per-repo `generation` counter
/// drops the abandoned Task's late write if it ever returns.
///
/// Mirrors `WorktreeStatsStoreInFlightRecoveryTests` (DIVERGE-4.4).
@Suite("""
PRStatusStore — in-flight stuck-refresh recovery

@spec PR-7.13: `PRStatusStore` shall time-bound its per-repo `inFlight` refresh guard so a hung `gh pr list` / `glab mr list` subprocess cannot permanently lock out subsequent polls and user-triggered refreshes. A dispatch whose start timestamp is within the inFlight cap (30 seconds) shall suppress a fresh refresh; beyond that cap, the prior dispatch shall be treated as abandoned and superseded, with the per-repo `generation` counter bumped so the abandoned Task's late write is dropped if it ever returns. Without this, a single stuck subprocess (network flake, rate-limit back-off, expired gh auth refresh loop) freezes that repo's worktrees' sidebar badges and breadcrumb PR buttons at their last-cached state until the app is relaunched — the user-observable shape "PR status only updates when I click between worktrees". Mirrors `WorktreeStatsStore`'s `DIVERGE-4.4` recovery pattern for the equivalent stats-store bug.
""")
struct PRStatusStoreInFlightRecoveryTests {

    @MainActor
    @Test func hungRefreshDoesNotLockOutSubsequentRefreshes() async throws {
        let callCount = SyncCounter()
        let freshPR = PRInfo(
            number: 42,
            title: "hello",
            url: URL(string: "https://github.com/foo/bar/pull/42")!,
            state: .open,
            checks: .none,
            fetchedAt: Date()
        )

        // First fetch hangs on a never-signaled AsyncStream. Models
        // a `gh pr list` subprocess stuck awaiting an HTTP response.
        let hang = AsyncStream<Void>.makeStream()
        let hangIterator = Box(hang.stream.makeAsyncIterator())

        let fetcher = HangingFetcher(
            callCount: callCount,
            hangIterator: hangIterator,
            fresh: freshPR
        )
        let origin = HostingOrigin(
            provider: .github, host: "github.com", owner: "foo", repo: "bar"
        )
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in origin }
        )
        let ticker = ManualTicker()
        let repo = RepoEntry(
            path: "/repo",
            displayName: "repo",
            worktrees: [WorktreeEntry(path: "/wt", branch: "feat", state: .running)]
        )
        store.start(ticker: ticker, getRepos: { [repo] })
        defer {
            hang.continuation.finish()
            store.stop()
        }

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.isInFlightForTesting("/repo"))

        // Fast-forward the in-flight timestamp past `refreshCadence`
        // so the next refresh treats the prior Task as abandoned.
        store.seedInFlightSinceForTesting(
            Date().addingTimeInterval(-3600),
            forRepo: "/repo"
        )

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")

        for _ in 0..<100 {
            if store.infos["/wt"] == freshPR { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(
            store.infos["/wt"] == freshPR,
            "a hung prior refresh Task must not prevent a later refresh from publishing fresh PRInfo"
        )
    }
}

/// Test double: first invocation suspends on a never-signaled
/// stream; subsequent invocations return the canned `fresh`
/// PRInfo as the snapshot for branch "feat".
private actor HangingFetcher: PRFetcher {
    private let callCount: SyncCounter
    private let hangIterator: Box<AsyncStream<Void>.Iterator>
    private let fresh: PRInfo

    init(
        callCount: SyncCounter,
        hangIterator: Box<AsyncStream<Void>.Iterator>,
        fresh: PRInfo
    ) {
        self.callCount = callCount
        self.hangIterator = hangIterator
        self.fresh = fresh
    }

    func fetch(
        origin: HostingOrigin,
        branchesOfInterest: Set<String>
    ) async throws -> RepoPRSnapshot {
        let n = callCount.incrementAndGet()
        if n == 1 {
            _ = await hangIterator.value.next()
            return RepoPRSnapshot(prsByBranch: [:])
        }
        return RepoPRSnapshot(prsByBranch: ["feat": fresh])
    }
}

/// Swift 6 doesn't let an AsyncStream.Iterator cross actor
/// boundaries directly — wrap in a Sendable box.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private final class SyncCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

