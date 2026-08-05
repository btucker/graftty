import Testing
import Foundation
@testable import GrafttyKit

/// DIVERGE-4.6: the five-second polling safety net must keep every running
/// worktree moving without launching a full-workspace subprocess burst.
/// Event-driven refreshes remain the prompt path; polling rotates through
/// four worktrees at a time so a missed event is repaired within
/// `ceil(runningCount / 4)` ticks while recurring command volume stays bounded.
@Suite("""
WorktreeStatsStore.pollTick

@spec DIVERGE-4.6: When the divergence-stats polling tick fires, the application shall recompute at most four eligible running worktrees and advance a round-robin cursor so every eligible worktree is recomputed within `ceil(runningCount / 4)` ticks. If the same tick dispatches a per-repo `git fetch`, that repository's worktrees shall be skipped because the fetch handler itself recomputes them on success; fetch-due repositories outside the network batch shall remain eligible for the local recompute batch.
""")
struct WorktreeStatsStorePollTickTests {

    @MainActor
    @Test func pollTickRefreshesSingleRunningWorktreeOnEveryTick() async throws {
        let compute = RecordingCompute()
        let store = WorktreeStatsStore(compute: compute.function, fetch: { _ in })

        // Repo-fetch cooldown is fresh (so Gate B is the path under
        // test). A single running worktree is the entire rotating batch,
        // so consecutive ticks still refresh it once the prior compute
        // clears its in-flight gate.
        store.seedLastRepoFetchForTesting(Date(), forRepo: "/r")

        let repo = RepoEntry(
            path: "/r",
            displayName: "r",
            worktrees: [WorktreeEntry(path: "/r/wt", branch: "feature", state: .running)]
        )

        await store.pollTickForTesting(repos: [repo])
        try await waitUntil(timeout: 2.0) { compute.callCount(for: "/r/wt") >= 1 }

        // Wait for the first compute Task to clear `inFlight` via apply().
        let inFlightCleared: () async -> Bool = { @MainActor in
            !store.isInFlightForTesting("/r/wt")
        }
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if await inFlightCleared() { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(await inFlightCleared())

        await store.pollTickForTesting(repos: [repo])
        try await waitUntil(timeout: 2.0) { compute.callCount(for: "/r/wt") >= 2 }
    }

    @MainActor
    @Test func pollTickSkipsStaleWorktrees() async throws {
        let compute = RecordingCompute()
        let store = WorktreeStatsStore(compute: compute.function, fetch: { _ in })

        store.seedLastRepoFetchForTesting(Date(), forRepo: "/r")
        // The unconditional per-worktree dispatch would otherwise fire,
        // but the worktree is stale so it must be skipped (PR-7.4 /
        // DIVERGE-1.6 parity — stale entries render no stats indicator
        // and the polling loop must not compute against a path that no
        // longer exists on disk).
        var staleWt = WorktreeEntry(path: "/r/gone", branch: "feature")
        staleWt.state = .stale
        let repo = RepoEntry(path: "/r", displayName: "r", worktrees: [staleWt])

        await store.pollTickForTesting(repos: [repo])
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(!compute.calledPaths.contains("/r/gone"))
    }

    @MainActor
    @Test("""
@spec PERF-1.3: The stats polling loop shall skip closed worktrees during its recurring local recompute cadence; a closed worktree exists on disk but has no live terminal surface, and repeatedly running local git scans for every tracked-but-closed row makes CPU scale with sidebar history rather than active work.
""")
    func pollTickSkipsClosedWorktrees() async throws {
        let compute = RecordingCompute()
        let store = WorktreeStatsStore(compute: compute.function, fetch: { _ in })

        store.seedLastRepoFetchForTesting(Date(), forRepo: "/r")
        let closedWt = WorktreeEntry(path: "/r/closed", branch: "feature", state: .closed)
        let repo = RepoEntry(path: "/r", displayName: "r", worktrees: [closedWt])

        await store.pollTickForTesting(repos: [repo])
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(!compute.calledPaths.contains("/r/closed"))
    }

    @MainActor
    @Test("""
@spec PERF-1.8: When many divergence refreshes are queued, the application shall run at most four compute pipelines concurrently so Git subprocess fan-out cannot starve interactive terminal input.
""")
    func refreshBoundsConcurrentDivergenceComputations() async throws {
        let compute = ConcurrencyRecordingCompute(delay: .milliseconds(100))
        let store = WorktreeStatsStore(compute: compute.function, fetch: { _ in })

        let worktrees = (0..<12).map {
            WorktreeEntry(
                path: "/r/wt-\($0)",
                branch: "feature-\($0)",
                state: .running
            )
        }
        for worktree in worktrees {
            store.refresh(
                worktreePath: worktree.path,
                repoPath: "/r",
                branch: worktree.branch
            )
        }
        try await waitUntil(timeout: 3.0) { compute.completedCount == worktrees.count }

        #expect(compute.maximumConcurrentCount <= 4)
    }

    @MainActor
    @Test("""
@spec PERF-1.11: When more than four running worktrees are eligible for the five-second stats safety-net, the application shall dispatch at most four per tick and rotate fairly so twelve worktrees require three ticks rather than twelve pipelines on every tick.
""")
    func pollTickBatchesAndRotatesAcrossRunningWorktrees() async throws {
        let compute = RecordingCompute()
        let store = WorktreeStatsStore(compute: compute.function, fetch: { _ in })
        store.seedLastRepoFetchForTesting(Date(), forRepo: "/r")

        let worktrees = (0..<12).map {
            WorktreeEntry(
                path: "/r/wt-\($0)",
                branch: "feature-\($0)",
                state: .running
            )
        }
        let repo = RepoEntry(path: "/r", displayName: "r", worktrees: worktrees)

        await store.pollTickForTesting(repos: [repo])
        let initiallyDispatched = worktrees.filter {
            store.isInFlightForTesting($0.path)
        }.count
        try #require(initiallyDispatched == 4)

        for expectedCount in [4, 8, 12] {
            try await waitUntilMainActor(timeout: 2.0) {
                store.stats.count == expectedCount
            }
            if expectedCount < worktrees.count {
                await store.pollTickForTesting(repos: [repo])
            }
        }

        #expect(compute.calledPaths == Set(worktrees.map(\.path)))
        #expect(worktrees.allSatisfy { compute.callCount(for: $0.path) == 1 })
    }

    @MainActor
    @Test func pollTickKeepsItsPlaceWhenSavedCandidateIsFetchGated() async throws {
        let compute = RecordingCompute()
        let fetch = BlockingFetch()
        let store = WorktreeStatsStore(
            compute: compute.function,
            fetch: fetch.function
        )
        let repos = (0..<12).map { index in
            let repoPath = "/repo-\(index)"
            store.seedLastRepoFetchForTesting(Date(), forRepo: repoPath)
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

        await store.pollTickForTesting(repos: repos)
        try await waitUntil(timeout: 2.0) { compute.totalCallCount == 4 }

        // Worktree 4 is the saved next-path anchor. Make only its repo fetch
        // due, then hold that fetch across the next two ticks so the anchor is
        // absent from the eligible local-compute candidates.
        store.seedLastRepoFetchForTesting(
            Date(timeIntervalSinceNow: -3600),
            forRepo: "/repo-4"
        )
        store.seedDefaultBranchForTesting("main", forRepo: "/repo-4")

        await store.pollTickForTesting(repos: repos)
        try await waitUntil(timeout: 2.0) {
            compute.totalCallCount == 8 && fetch.startedCount == 1
        }
        await store.pollTickForTesting(repos: repos)
        try await waitUntil(timeout: 2.0) { compute.totalCallCount == 12 }

        let continuouslyEligible = Set(repos.indices.filter { $0 != 4 }.map {
            "/repo-\($0)/worktree"
        })
        #expect(continuouslyEligible.isSubset(of: compute.calledPaths))

        fetch.resumeAll()
        try await waitUntil(timeout: 2.0) { fetch.completedCount == 1 }
    }

    @MainActor
    @Test("""
@spec PERF-1.13: When the thirty-second divergence fetch cadence becomes due for more than four repositories at once, the application shall keep at most four repository fetches outstanding and advance a round-robin cursor so recurring network work cannot fill the shared background-process queue ahead of other pollers.
""")
    func repoFetchesAreSubmittedInRotatingBatches() async throws {
        let fetch = ConcurrencyRecordingFetch(delay: .milliseconds(100))
        let store = WorktreeStatsStore(
            compute: { _, _, _, _ in
                WorktreeStatsStore.ComputeResult(defaultBranch: "main", stats: nil)
            },
            fetch: fetch.function
        )
        let repos = (0..<12).map { index in
            let repoPath = "/repo-\(index)"
            store.seedDefaultBranchForTesting("main", forRepo: repoPath)
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

        for expectedCompletedCount in [4, 8, 12] {
            await store.pollTickForTesting(repos: repos)
            let claimedRepoCount = repos.filter {
                store.isInFlightRepoForTesting($0.path)
            }.count
            try #require(claimedRepoCount == 4)
            try await waitUntil(timeout: 3.0) {
                fetch.completedCount == expectedCompletedCount
            }
        }

        #expect(fetch.maximumConcurrentCount <= 4)
    }

    @MainActor
    @Test func slowRepoFetchesDoNotAccumulateAcrossPollTicks() async throws {
        let fetch = BlockingFetch()
        let store = WorktreeStatsStore(
            compute: { _, _, _, _ in
                WorktreeStatsStore.ComputeResult(defaultBranch: "main", stats: nil)
            },
            fetch: fetch.function
        )
        let repos = (0..<12).map { index in
            let repoPath = "/repo-\(index)"
            store.seedDefaultBranchForTesting("main", forRepo: repoPath)
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

        for _ in 0..<3 {
            await store.pollTickForTesting(repos: repos)
        }
        try await waitUntil(timeout: 2.0) { fetch.startedCount == 4 }

        #expect(fetch.startedCount == 4)
        #expect(repos.filter { store.isInFlightRepoForTesting($0.path) }.count == 4)

        fetch.resumeAll()
        try await waitUntil(timeout: 2.0) { fetch.completedCount == 4 }
    }

    @MainActor
    @Test("""
@spec DIVERGE-4.10: When the divergence-stats polling tick visits a repository whose `git fetch` cooldown has elapsed but which currently has no running worktrees, the application shall not mark that repository as having an in-flight fetch. Without this, claiming a fetch slot before checking for running worktrees leaves the repo path latched in `inFlightRepos`: every subsequent poll classifies it as active, skips the local-compute gate, and never re-invokes `WorktreeStatsStore.refresh`. The user-visible shape is a sidebar gutter whose ↓N count remains frozen until the app is relaunched.
""")
    func pollTickWithNoRunningWorktreesDoesNotLeakInFlightRepoSlot() async throws {
        let compute = RecordingCompute()
        let store = WorktreeStatsStore(compute: compute.function, fetch: { _ in })

        let closedWt = WorktreeEntry(path: "/r/closed", branch: "feature", state: .closed)
        let repoEmpty = RepoEntry(path: "/r", displayName: "r", worktrees: [closedWt])
        await store.pollTickForTesting(repos: [repoEmpty])

        // Seed the cooldown so the second tick falls through to Gate B
        // without entering `performRepoFetch` (which would shell out to
        // git against the fake `/r` path).
        store.seedLastRepoFetchForTesting(Date(), forRepo: "/r")
        let runningWt = WorktreeEntry(path: "/r/running", branch: "feature", state: .running)
        let repoWithRunning = RepoEntry(path: "/r", displayName: "r", worktrees: [runningWt])
        await store.pollTickForTesting(repos: [repoWithRunning])

        try await waitUntil(timeout: 2.0) { compute.callCount(for: "/r/running") >= 1 }
    }

    @MainActor
    @Test("""
@spec DIVERGE-4.11: If a per-repo `git fetch` dispatched by the divergence-stats polling tick remains in flight past the abandonment threshold despite its subprocess deadline, then the application shall treat the repo slot as abandoned and let a later tick dispatch a fresh fetch rather than latch the repo path for the lifetime of the session.
""")
    func pollTickSupersedesAbandonedRepoFetchSlot() async throws {
        let compute = RecordingCompute()
        let store = WorktreeStatsStore(compute: compute.function, fetch: { _ in })

        // A previous `git fetch` hung and never released its slot. Seed
        // the marker well past the abandonment threshold so this tick
        // must treat it as abandoned.
        store.seedInFlightRepoForTesting(
            Date(timeIntervalSinceNow: -3600),
            forRepo: "/r"
        )
        // Cooldown elapsed and default branch known, so once the stale
        // slot is abandoned the fetch dispatches and reaches the
        // per-worktree refresh (the injected fetch returns immediately).
        store.seedLastRepoFetchForTesting(
            Date(timeIntervalSinceNow: -3600),
            forRepo: "/r"
        )
        store.seedDefaultBranchForTesting("main", forRepo: "/r")

        let runningWt = WorktreeEntry(path: "/r/running", branch: "feature", state: .running)
        let repo = RepoEntry(path: "/r", displayName: "r", worktrees: [runningWt])

        await store.pollTickForTesting(repos: [repo])

        // With the latch fixed, the abandoned fetch is superseded and the
        // fresh one recomputes the running worktree's divergence. A bare-
        // `Set` latch would short-circuit forever and never call compute.
        try await waitUntil(timeout: 2.0) { compute.callCount(for: "/r/running") >= 1 }
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(condition(), "waitUntil timed out")
    }

    @MainActor
    private func waitUntilMainActor(
        timeout: TimeInterval,
        condition: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(condition(), "waitUntilMainActor timed out")
    }
}

/// Thread-safe recorder for injected `ComputeFunction` invocations.
/// A plain class + `NSLock` is deliberately simpler than an actor here:
/// the `@Sendable` compute closure needs to be callable from a detached
/// Task while the @MainActor test asserts — an actor-isolated getter
/// would force the test to await every observation and the `function`
/// property itself would become actor-isolated.
private final class RecordingCompute: @unchecked Sendable {
    private let lock = NSLock()
    private var _calledPaths: Set<String> = []
    private var _callCounts: [String: Int] = [:]

    var calledPaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return _calledPaths
    }

    var totalCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCounts.values.reduce(0, +)
    }

    func callCount(for path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return _callCounts[path, default: 0]
    }

    var function: WorktreeStatsStore.ComputeFunction {
        { [weak self] worktreePath, _, _, _ in
            self?.record(worktreePath)
            // Return a non-nil stats so apply() clears the in-flight
            // gate — the second-tick assertion needs the slot freed.
            return WorktreeStatsStore.ComputeResult(
                defaultBranch: "main",
                stats: WorktreeStats(ahead: 0, behind: 0, insertions: 0, deletions: 0)
            )
        }
    }

    private func record(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        _calledPaths.insert(path)
        _callCounts[path, default: 0] += 1
    }
}

private final class BlockingFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var _startedCount = 0
    private var _completedCount = 0

    var startedCount: Int {
        lock.withLock { _startedCount }
    }

    var completedCount: Int {
        lock.withLock { _completedCount }
    }

    var function: WorktreeStatsStore.FetchFunction {
        { [weak self] _ in
            guard let self else { return }
            await withCheckedContinuation { continuation in
                self.lock.withLock {
                    self._startedCount += 1
                    self.continuations.append(continuation)
                }
            }
            self.lock.withLock {
                self._completedCount += 1
            }
        }
    }

    func resumeAll() {
        let pending = lock.withLock {
            let pending = continuations
            continuations.removeAll()
            return pending
        }
        for continuation in pending {
            continuation.resume()
        }
    }
}

/// Records how much injected stats work overlaps. The fixed delay keeps every
/// invocation in flight long enough for an unbounded poll fan-out to overlap,
/// while remaining short enough that the bounded implementation finishes the
/// twelve-worktree benchmark in three waves.
private final class ConcurrencyRecordingCompute: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: Duration
    private var activeCount = 0
    private var _completedCount = 0
    private var _maximumConcurrentCount = 0

    init(delay: Duration) {
        self.delay = delay
    }

    var completedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _completedCount
    }

    var maximumConcurrentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _maximumConcurrentCount
    }

    var function: WorktreeStatsStore.ComputeFunction {
        { [weak self] _, _, _, _ in
            guard let self else {
                return WorktreeStatsStore.ComputeResult(defaultBranch: nil, stats: nil)
            }
            self.recordStart()
            try? await Task.sleep(for: self.delay)
            self.recordCompletion()
            return WorktreeStatsStore.ComputeResult(
                defaultBranch: "main",
                stats: WorktreeStats(ahead: 0, behind: 0, insertions: 0, deletions: 0)
            )
        }
    }

    private func recordStart() {
        lock.lock(); defer { lock.unlock() }
        activeCount += 1
        _maximumConcurrentCount = max(_maximumConcurrentCount, activeCount)
    }

    private func recordCompletion() {
        lock.lock(); defer { lock.unlock() }
        activeCount -= 1
        _completedCount += 1
    }
}

private final class ConcurrencyRecordingFetch: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: Duration
    private var activeCount = 0
    private var _completedCount = 0
    private var _maximumConcurrentCount = 0

    init(delay: Duration) {
        self.delay = delay
    }

    var completedCount: Int {
        lock.withLock { _completedCount }
    }

    var maximumConcurrentCount: Int {
        lock.withLock { _maximumConcurrentCount }
    }

    var function: WorktreeStatsStore.FetchFunction {
        { [weak self] _ in
            guard let self else { return }
            self.lock.withLock {
                self.activeCount += 1
                self._maximumConcurrentCount = max(
                    self._maximumConcurrentCount,
                    self.activeCount
                )
            }
            try await Task.sleep(for: self.delay)
            self.lock.withLock {
                self.activeCount -= 1
                self._completedCount += 1
            }
        }
    }
}
