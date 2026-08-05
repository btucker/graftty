import Foundation
import Testing
@testable import GrafttyKit

@Suite("Shared background-process budget")
struct BackgroundProcessLimiterIntegrationTests {
    @MainActor
    @Test("""
    @spec PERF-1.14: When the stats, remote-branch, and PR polling cadences align in a twelve-repository workspace, the application shall run at most four background subprocess pipelines in aggregate rather than allowing each poller to consume an independent concurrency budget.
    """)
    func alignedPollersShareOneAggregateLimit() async throws {
        let limiter = BackgroundProcessLimiter(capacity: 4)
        let recorder = AlignedPollerRecorder()
        defer { recorder.resumeAll() }
        let origin = HostingOrigin(
            provider: .github,
            host: "github.com",
            owner: "example",
            repo: "repo"
        )

        let statsStore = WorktreeStatsStore(
            compute: { _, _, _, _ in
                await recorder.record(
                    "stats-compute",
                    returning: WorktreeStatsStore.ComputeResult(
                        defaultBranch: "main",
                        stats: WorktreeStats(
                            ahead: 0,
                            behind: 0,
                            insertions: 0,
                            deletions: 0
                        )
                    )
                )
            },
            fetch: { _ in
                _ = await recorder.record("stats-fetch", returning: ())
            },
            backgroundProcessLimiter: limiter
        )
        let remoteBranchStore = RemoteBranchStore(
            list: { _ in
                await recorder.record(
                    "remote-list",
                    returning: RemoteBranchSnapshot()
                )
            },
            backgroundProcessLimiter: limiter
        )
        let prStatusStore = PRStatusStore(
            fetcherFor: { _ in
                AlignedPollerPRFetcher(recorder: recorder)
            },
            detectHost: { _ in
                await recorder.record("pr-detect", returning: origin)
            },
            backgroundProcessLimiter: limiter
        )

        let repos = (0..<12).map { index in
            let repoPath = "/repo-\(index)"
            statsStore.seedDefaultBranchForTesting("main", forRepo: repoPath)
            return RepoEntry(
                path: repoPath,
                displayName: "repo-\(index)",
                worktrees: [
                    WorktreeEntry(
                        path: "\(repoPath)/worktree",
                        branch: "feature-\(index)",
                        state: .running
                    ),
                ]
            )
        }

        let remoteTicker = ManualTicker()
        remoteBranchStore.start(ticker: remoteTicker, getRepos: { repos })
        let prTicker = ManualTicker()
        prStatusStore.start(ticker: prTicker, getRepos: { repos })

        await statsStore.pollTickForTesting(repos: repos)
        await remoteTicker.fire()
        await prTicker.fire()

        try await waitUntil(timeout: 3.0) {
            recorder.activeCount >= 4
        }
        try #require(recorder.activeCount == 4)
        recorder.resumeAll()

        try await waitUntil(timeout: 3.0) {
            recorder.completedCount == 24
        }

        #expect(recorder.maximumConcurrentCount <= 4)
        #expect(recorder.count(for: "stats-fetch") == 4)
        #expect(recorder.count(for: "stats-compute") == 8)
        #expect(recorder.count(for: "remote-list") == 4)
        #expect(recorder.count(for: "pr-detect") == 4)
        #expect(recorder.count(for: "pr-fetch") == 4)
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(condition(), "waitUntil timed out")
    }
}

private final class AlignedPollerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _activeCount = 0
    private var _completedCount = 0
    private var _maximumConcurrentCount = 0
    private var counts: [String: Int] = [:]
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    var activeCount: Int {
        lock.withLock { _activeCount }
    }

    var completedCount: Int {
        lock.withLock { _completedCount }
    }

    var maximumConcurrentCount: Int {
        lock.withLock { _maximumConcurrentCount }
    }

    func count(for label: String) -> Int {
        lock.withLock { counts[label, default: 0] }
    }

    func record<T: Sendable>(_ label: String, returning value: T) async -> T {
        let shouldWait = lock.withLock {
            _activeCount += 1
            _maximumConcurrentCount = max(_maximumConcurrentCount, _activeCount)
            return !released
        }
        if shouldWait {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if released { return true }
                    continuations.append(continuation)
                    return false
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        }
        lock.withLock {
            _activeCount -= 1
            _completedCount += 1
            counts[label, default: 0] += 1
        }
        return value
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

private final class AlignedPollerPRFetcher: PRFetcher, @unchecked Sendable {
    private let recorder: AlignedPollerRecorder

    init(recorder: AlignedPollerRecorder) {
        self.recorder = recorder
    }

    func fetch(
        origin: HostingOrigin,
        branchesOfInterest: Set<String>
    ) async throws -> RepoPRSnapshot {
        await recorder.record(
            "pr-fetch",
            returning: RepoPRSnapshot(prsByBranch: [:])
        )
    }
}
