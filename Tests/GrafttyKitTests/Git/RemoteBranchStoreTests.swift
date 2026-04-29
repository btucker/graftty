import Testing
import Foundation
@testable import GrafttyKit

@Suite("RemoteBranchStore")
struct RemoteBranchStoreTests {
    @Test func parseStripsOriginPrefixPreservesSlashesAndSkipsHead() {
        let refs = """
        origin/HEAD
        origin/main
        origin/feature/foo
        upstream/ignored

        """

        #expect(RemoteBranchStore.parseRefsForTesting(refs) == [
            "main",
            "feature/foo",
        ])
    }

    @MainActor
    @Test func refreshPublishesBranchesAndReportsHasRemote() async throws {
        let lister = RecordingRemoteBranchLister(results: [
            "/repo": .success(["main", "feature/foo"]),
        ])
        let store = RemoteBranchStore(list: lister.list)

        store.refresh(repoPath: "/repo")

        try await waitUntil(timeout: 1.0) {
            store.hasRemote(repoPath: "/repo", branch: "feature/foo")
        }
        #expect(!store.hasRemote(repoPath: "/repo", branch: "missing"))
    }

    @MainActor
    @Test func hasRemoteRejectsEmptyWhitespaceAndSentinelBranches() async throws {
        let store = RemoteBranchStore(list: { _ in ["main"] })
        store.refresh(repoPath: "/repo")
        try await waitUntil(timeout: 1.0) {
            store.hasRemote(repoPath: "/repo", branch: "main")
        }

        #expect(!store.hasRemote(repoPath: "/repo", branch: ""))
        #expect(!store.hasRemote(repoPath: "/repo", branch: "   "))
        #expect(!store.hasRemote(repoPath: "/repo", branch: "(detached)"))
    }

    @MainActor
    @Test func failedRefreshPreservesPreviousSnapshot() async throws {
        let lister = RecordingRemoteBranchLister(results: [
            "/repo": .success(["main"]),
        ])
        let store = RemoteBranchStore(list: lister.list)
        store.refresh(repoPath: "/repo")
        try await waitUntil(timeout: 1.0) {
            store.hasRemote(repoPath: "/repo", branch: "main")
        }

        lister.set(result: .failure(TestError.boom), for: "/repo")
        store.refresh(repoPath: "/repo")
        try await Task.sleep(for: .milliseconds(100))

        #expect(store.hasRemote(repoPath: "/repo", branch: "main"))
    }

    @MainActor
    @Test func clearDropsSnapshot() async throws {
        let store = RemoteBranchStore(list: { _ in ["main"] })
        store.refresh(repoPath: "/repo")
        try await waitUntil(timeout: 1.0) {
            store.hasRemote(repoPath: "/repo", branch: "main")
        }

        store.clear(repoPath: "/repo")

        #expect(!store.hasRemote(repoPath: "/repo", branch: "main"))
    }

    @MainActor
    @Test func clearPreventsSuspendedRefreshFromRepopulatingSnapshot() async throws {
        let lister = RecordingRemoteBranchLister(
            results: ["/repo": .success(["main"])],
            suspendUntilResumed: true
        )
        let store = RemoteBranchStore(list: lister.list)
        var completed = false

        store.refresh(repoPath: "/repo") {
            completed = true
        }
        try await waitUntil(timeout: 1.0) {
            lister.invocationCount(for: "/repo") == 1
        }

        store.clear(repoPath: "/repo")
        lister.resumeAll()

        try await waitUntil(timeout: 1.0) {
            completed
        }
        #expect(!store.hasRemote(repoPath: "/repo", branch: "main"))
    }

    @MainActor
    @Test func refreshDedupesWhileListerCallIsInFlight() async throws {
        let lister = RecordingRemoteBranchLister(
            results: ["/repo": .success(["main"])],
            suspendUntilResumed: true
        )
        let store = RemoteBranchStore(list: lister.list)

        store.refresh(repoPath: "/repo")
        store.refresh(repoPath: "/repo")

        try await waitUntil(timeout: 1.0) {
            lister.invocationCount(for: "/repo") == 1
        }
        #expect(lister.invocationCount(for: "/repo") == 1)

        lister.resumeAll()

        try await waitUntil(timeout: 1.0) {
            store.hasRemote(repoPath: "/repo", branch: "main")
        }
    }

    @MainActor
    @Test func dedupedRefreshRunsAllCompletions() async throws {
        let lister = RecordingRemoteBranchLister(
            results: ["/repo": .success(["main"])],
            suspendUntilResumed: true
        )
        let store = RemoteBranchStore(list: lister.list)
        var completions: [String] = []

        store.refresh(repoPath: "/repo") {
            completions.append("first")
        }
        store.refresh(repoPath: "/repo") {
            completions.append("second")
        }

        try await waitUntil(timeout: 1.0) {
            lister.invocationCount(for: "/repo") == 1
        }
        lister.resumeAll()
        try await waitUntil(timeout: 1.0) {
            lister.invocationCount(for: "/repo") == 2
        }
        lister.resumeAll()

        try await waitUntil(timeout: 1.0) {
            completions.count == 2
        }
        #expect(completions == ["first", "second"])
    }

    @MainActor
    @Test func refreshDuringInFlightRerunsBeforeLaterCompletion() async throws {
        let lister = RecordingRemoteBranchLister(
            results: ["/repo": .success(["old"])],
            suspendUntilResumed: true
        )
        let store = RemoteBranchStore(list: lister.list)
        var secondCompletionSnapshot: Set<String>?

        store.refresh(repoPath: "/repo")
        try await waitUntil(timeout: 1.0) {
            lister.invocationCount(for: "/repo") == 1
        }

        lister.set(result: .success(["new"]), for: "/repo")
        store.refresh(repoPath: "/repo") {
            secondCompletionSnapshot = store.branchesByRepo["/repo"]
        }

        #expect(lister.invocationCount(for: "/repo") == 1)
        lister.resumeAll()

        try await waitUntil(timeout: 1.0) {
            lister.invocationCount(for: "/repo") == 2
        }
        #expect(secondCompletionSnapshot == nil)
        #expect(store.hasRemote(repoPath: "/repo", branch: "old"))
        #expect(!store.hasRemote(repoPath: "/repo", branch: "new"))

        lister.resumeAll()

        try await waitUntil(timeout: 1.0) {
            secondCompletionSnapshot == ["new"]
        }
        #expect(lister.invocationCount(for: "/repo") == 2)
        #expect(!store.hasRemote(repoPath: "/repo", branch: "old"))
        #expect(store.hasRemote(repoPath: "/repo", branch: "new"))
    }

    @MainActor
    @Test func clearReleasesPendingRerunCompletion() async throws {
        let lister = RecordingRemoteBranchLister(
            results: ["/repo": .success(["main"])],
            suspendUntilResumed: true
        )
        let store = RemoteBranchStore(list: lister.list)
        var completionRan = false

        store.refresh(repoPath: "/repo")
        try await waitUntil(timeout: 1.0) {
            lister.invocationCount(for: "/repo") == 1
        }

        var token: CompletionToken? = CompletionToken()
        weak let weakToken = token
        store.refresh(repoPath: "/repo") { [token] in
            completionRan = true
            _ = token
        }
        token = nil
        #expect(weakToken != nil)

        store.clear(repoPath: "/repo")
        lister.resumeAll()

        try await waitUntil(timeout: 1.0) {
            lister.invocationCount(for: "/repo") == 1 && !completionRan
        }
        #expect(weakToken == nil)
    }

    @MainActor
    @Test func startRefreshesEachTrackedRepoOnTickerFire() async throws {
        let lister = RecordingRemoteBranchLister(results: [
            "/a": .success(["main"]),
            "/b": .success(["feature"]),
        ])
        let ticker = CapturingTicker()
        let store = RemoteBranchStore(list: lister.list)
        let repos = [
            RepoEntry(path: "/a", displayName: "a", worktrees: []),
            RepoEntry(path: "/b", displayName: "b", worktrees: []),
        ]

        store.start(ticker: ticker, getRepos: { repos })
        await ticker.fire()

        try await waitUntil(timeout: 1.0) {
            store.hasRemote(repoPath: "/a", branch: "main")
                && store.hasRemote(repoPath: "/b", branch: "feature")
        }
    }

    @MainActor
    @Test func stopPreventsOldTickerFireFromRefreshingRepos() async throws {
        let lister = RecordingRemoteBranchLister(results: [
            "/repo": .success(["main"]),
        ])
        let ticker = CapturingTicker()
        let store = RemoteBranchStore(list: lister.list)

        store.start(
            ticker: ticker,
            getRepos: { [RepoEntry(path: "/repo", displayName: "repo", worktrees: [])] }
        )
        store.stop()
        await ticker.fire()
        try await Task.sleep(for: .milliseconds(100))

        #expect(lister.invocationCount(for: "/repo") == 0)
        #expect(ticker.stopCallCount == 1)
    }

    @MainActor
    @Test func secondStartStopsFirstTickerAndUsesSecondRepoSupplier() async throws {
        let lister = RecordingRemoteBranchLister(results: [
            "/old": .success(["old"]),
            "/new": .success(["new"]),
        ])
        let firstTicker = CapturingTicker()
        let secondTicker = CapturingTicker()
        let store = RemoteBranchStore(list: lister.list)

        store.start(
            ticker: firstTicker,
            getRepos: { [RepoEntry(path: "/old", displayName: "old", worktrees: [])] }
        )
        store.start(
            ticker: secondTicker,
            getRepos: { [RepoEntry(path: "/new", displayName: "new", worktrees: [])] }
        )

        await firstTicker.fire()
        await secondTicker.fire()

        try await waitUntil(timeout: 1.0) {
            store.hasRemote(repoPath: "/new", branch: "new")
        }
        #expect(!store.hasRemote(repoPath: "/old", branch: "old"))
        #expect(lister.invocationCount(for: "/old") == 0)
        #expect(firstTicker.stopCallCount == 1)
    }

    @MainActor
    @Test func pulseForwardsToActiveTickerAndDoesNothingAfterStop() {
        let ticker = CapturingTicker()
        let store = RemoteBranchStore(list: { _ in [] })

        store.start(ticker: ticker, getRepos: { [] })
        store.pulse()
        #expect(ticker.pulseCallCount == 1)

        store.stop()
        store.pulse()
        #expect(ticker.pulseCallCount == 1)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let succeeded = await condition()
        #expect(succeeded, "waitUntil timed out")
    }
}

@MainActor
private final class CapturingTicker: PollingTickerLike {
    private var onTick: (@MainActor () async -> Void)?
    private(set) var stopCallCount = 0
    private(set) var pulseCallCount = 0

    func start(onTick: @MainActor @escaping () async -> Void) {
        self.onTick = onTick
    }

    func stop() {
        stopCallCount += 1
    }

    func pulse() {
        pulseCallCount += 1
    }

    func fire() async {
        await onTick?()
    }
}

private enum TestError: Error {
    case boom
}

private final class CompletionToken {}

private final class RecordingRemoteBranchLister: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: Result<Set<String>, Error>]
    private var invocations: [String: Int] = [:]
    private var continuations: [(Result<Set<String>, Error>, CheckedContinuation<Set<String>, Error>)] = []
    private let suspendUntilResumed: Bool

    init(
        results: [String: Result<Set<String>, Error>],
        suspendUntilResumed: Bool = false
    ) {
        self.results = results
        self.suspendUntilResumed = suspendUntilResumed
    }

    var list: RemoteBranchStore.ListFunction {
        { [weak self] repoPath in
            guard let self else { return [] }
            return try await self.list(repoPath: repoPath)
        }
    }

    func set(result: Result<Set<String>, Error>, for repoPath: String) {
        lock.withLock {
            results[repoPath] = result
        }
    }

    func invocationCount(for repoPath: String) -> Int {
        lock.withLock {
            invocations[repoPath, default: 0]
        }
    }

    func resumeAll() {
        let pending = lock.withLock {
            let pending = continuations
            continuations.removeAll()
            return pending
        }

        for (result, continuation) in pending {
            switch result {
            case .success(let branches):
                continuation.resume(returning: branches)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private func list(repoPath: String) async throws -> Set<String> {
        let result = lock.withLock {
            invocations[repoPath, default: 0] += 1
            return results[repoPath] ?? .success([])
        }

        if suspendUntilResumed {
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    continuations.append((result, continuation))
                }
            }
        }

        return try result.get()
    }
}
