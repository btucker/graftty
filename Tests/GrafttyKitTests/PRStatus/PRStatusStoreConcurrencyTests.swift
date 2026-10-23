import Foundation
import Testing
@testable import GrafttyKit
import GrafttyKitTestSupport

@Suite("PRStatusStore background concurrency")
struct PRStatusStoreConcurrencyTests {
    @MainActor
    @Test("""
    @spec PERF-1.10: When ordinary PR polling scans more than four repositories, the application shall dispatch at most four repositories per thirty-second tick and rotate fairly so twelve repositories require three ticks rather than twelve host queries at once.
    """)
    func pollingBatchesAndRotatesAcrossRepositories() async throws {
        let fetcher = RecordingPRFetcher()
        let work = ManualWorkQueue()
        let origin = HostingOrigin(
            provider: .github,
            host: "github.com",
            owner: "example",
            repo: "repo"
        )
        let ticker = ManualTicker()
        let store = PRStatusStore(
            fetcherFor: { _ in fetcher },
            detectHost: { _ in origin },
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        store.dispatchWork = work.enqueue
        let repos = (0..<12).map { index in
            RepoEntry(
                path: "/repo-\(index)",
                displayName: "repo-\(index)",
                worktrees: [
                    WorktreeEntry(
                        path: "/repo-\(index)/worktree",
                        branch: "feature-\(index)",
                        state: .running
                    ),
                ]
            )
        }

        store.start(ticker: ticker, getRepos: { repos })
        for expectedCompletedCount in [4, 8, 12] {
            await ticker.fire()
            let dispatchedCount = repos.filter {
                store.isInFlightForTesting($0.path)
            }.count
            try #require(dispatchedCount == 4)
            try #require(work.count == 4)
            await work.runBatch()
            #expect(fetcher.completedCount == expectedCompletedCount)
            #expect(repos.allSatisfy { !store.isInFlightForTesting($0.path) })
        }

        #expect(fetcher.branches == Set((0..<12).map { "feature-\($0)" }))
    }

    @MainActor
    @Test func slowPollsDoNotAccumulateAcrossTicksOrForcedPulses() async throws {
        let fetcher = BlockingPRFetcher()
        let origin = HostingOrigin(
            provider: .github,
            host: "github.com",
            owner: "example",
            repo: "repo"
        )
        let ticker = ManualTicker()
        let store = PRStatusStore(
            fetcherFor: { _ in fetcher },
            detectHost: { _ in origin },
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        let repos = (0..<12).map { index in
            RepoEntry(
                path: "/repo-\(index)",
                displayName: "repo-\(index)",
                worktrees: [
                    WorktreeEntry(
                        path: "/repo-\(index)/worktree",
                        branch: "feature-\(index)",
                        state: .running
                    ),
                ]
            )
        }
        store.start(ticker: ticker, getRepos: { repos })
        defer { store.stop() }

        store.pulse()
        for _ in 0..<3 {
            await ticker.fire()
        }

        #expect(repos.filter { store.isInFlightForTesting($0.path) }.count == 4)
        #expect(fetcher.startedCount <= 4)

        fetcher.resumeAll()
    }


}

private final class BlockingPRFetcher: PRFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var _startedCount = 0
    private var released = false

    var startedCount: Int {
        lock.withLock { _startedCount }
    }

    func fetch(
        origin: HostingOrigin,
        branchesOfInterest: Set<String>
    ) async throws -> RepoPRSnapshot {
        let shouldWait = lock.withLock {
            _startedCount += 1
            return !released
        }
        if shouldWait {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if released {
                        continuation.resume()
                    } else {
                        continuations.append(continuation)
                    }
                }
            }
        }
        return RepoPRSnapshot(prsByBranch: [:])
    }

    func resumeAll() {
        let pending = lock.withLock {
            released = true
            let pending = continuations
            continuations.removeAll()
            return pending
        }
        for continuation in pending {
            continuation.resume()
        }
    }
}

private final class RecordingPRFetcher: PRFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _completedCount = 0
    private var _branches: Set<String> = []

    var completedCount: Int { lock.withLock { _completedCount } }
    var branches: Set<String> { lock.withLock { _branches } }

    func fetch(origin: HostingOrigin, branchesOfInterest: Set<String>) async throws -> RepoPRSnapshot {
        lock.withLock {
            _completedCount += 1
            _branches.formUnion(branchesOfInterest)
        }
        return RepoPRSnapshot(prsByBranch: [:])
    }
}
