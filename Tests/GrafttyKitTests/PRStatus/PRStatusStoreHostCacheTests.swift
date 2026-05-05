import Testing
import Foundation
@testable import GrafttyKit

/// The `hostByRepo` cache was keyed off the raw `detectHost` return
/// value, where nil conflated two cases: "repo genuinely has no
/// origin" (legitimately cacheable) and "detect threw transiently"
/// (must not be cached, or a transient git-binary or spawn failure
/// at the first poll poisons the repo's PR tracking for the whole
/// session). This test pins the distinction.
@Suite("PRStatusStore — hostByRepo cache-poisoning")
struct PRStatusStoreHostCacheTests {

    enum StubError: Error { case boom }

    @MainActor
    @Test func transientDetectFailureDoesNotPoisonCache() async throws {
        // detectHost throws on call 1 (simulating .notFound / .launchFailed
        // from GitRunner), succeeds on call 2. After the first refresh,
        // the second must re-run detect rather than re-use the cached nil.
        let origin = HostingOrigin(
            provider: .github, host: "github.com", owner: "foo", repo: "bar"
        )
        let callLog = SyncCounter()
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in ReturningFetcher(info: nil) },
            detectHost: { _ in
                let n = callLog.incrementAndGet()
                if n == 1 { throw StubError.boom }
                return origin
            }
        )

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "main")
        for _ in 0..<100 {
            if callLog.current() >= 1 && !store.isInFlightForTesting("/repo") { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        // Second refresh should retry detect. If the nil was cached, it
        // would skip detect and still report absent without calling again.
        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "main")
        for _ in 0..<100 {
            if callLog.current() >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(
            callLog.current() >= 2,
            "transient detect failure must not poison the hostByRepo cache"
        )
    }

    @MainActor
    @Test func successfulDetectStillCaches() async throws {
        // Counterpart: a repo with a resolvable origin caches after the
        // first successful detect — second refresh reuses it, no extra
        // subprocess. Pins that the fix doesn't regress caching for the
        // happy path.
        let origin = HostingOrigin(
            provider: .github, host: "github.com", owner: "foo", repo: "bar"
        )
        let callLog = SyncCounter()
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in ReturningFetcher(info: nil) },
            detectHost: { _ in
                _ = callLog.incrementAndGet()
                return origin
            }
        )

        store.refresh(worktreePath: "/a", repoPath: "/repo", branch: "main")
        for _ in 0..<100 {
            if callLog.current() >= 1 && !store.isInFlightForTesting("/repo") { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        store.refresh(worktreePath: "/b", repoPath: "/repo", branch: "main")
        try await Task.sleep(for: .milliseconds(120))

        #expect(callLog.current() == 1, "successful detect should be cached and reused")
    }
}

/// A fetcher stub that always returns the same snapshot.
private final class ReturningFetcher: PRFetcher, @unchecked Sendable {
    let snapshot: RepoPRSnapshot
    init(info: PRInfo?) {
        if let info {
            self.snapshot = RepoPRSnapshot(prsByBranch: ["main": info])
        } else {
            self.snapshot = RepoPRSnapshot(prsByBranch: [:])
        }
    }
    func fetch(
        origin: HostingOrigin,
        branchesOfInterest: Set<String>
    ) async throws -> RepoPRSnapshot { snapshot }
}

/// Thread-safe counter for `@Sendable` closures.
private final class SyncCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func incrementAndGet() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
    func current() -> Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
