import Testing
import Foundation
@testable import GrafttyKit

@Suite("RemoteBranchStore")
struct RemoteBranchStoreTests {
    @Test("""
    @spec GIT-2.11: When recurring remote-branch polling scans local Git refs, the application shall time-bound every subprocess so a filesystem-blocked repository releases its in-flight slot and retained pipe descriptors without requiring an application restart.
    """)
    func defaultListBoundsEveryLocalGitProbe() async throws {
        let executor = RemoteBranchTimeoutRecordingExecutor()
        let list = RemoteBranchStore.makeDefaultList(executor: executor)

        _ = try await list("/repo")

        let invocations = executor.recordedInvocations
        #expect(invocations.count == 1)
        #expect(invocations.allSatisfy {
            guard let timeout = $0 else { return false }
            return timeout > .zero && timeout <= .seconds(20)
        })
    }

    @Test("""
    @spec PERF-1.12: When the recurring remote-branch poll reads a repository's refs, the application shall obtain remote branches, local branches, upstream mappings, and the origin default branch with one Git subprocess.
    """)
    func defaultListCombinesRefMetadataIntoOneGitInvocation() async throws {
        let executor = CombinedRefScanExecutor()
        let list = RemoteBranchStore.makeDefaultList(executor: executor)

        let snapshot = try await list("/repo")

        #expect(executor.invocationCount == 1)
        #expect(Set(snapshot.remoteBranches.map(\.name)) == ["main", "feature/remote"])
        #expect(Set(snapshot.localBranches.map(\.name)) == [
            "main", "feature/local", "non-origin",
        ])
        #expect(snapshot.upstreams == [
            "main": "main",
            "feature/local": "feature/remote",
        ])
        #expect(snapshot.defaultBranch == "main")
        let expectedMainDate = ISO8601DateFormatter.dateFromInternetDateTime(
            "2026-05-10T12:30:00-05:00"
        )
        #expect(
            snapshot.remoteBranches.first { $0.name == "main" }?.lastCommitDate
                == expectedMainDate
        )
    }

    @Test func combinedRefScanFallsBackToConventionalDefaultBranch() {
        let snapshot = RemoteBranchStore.parseCombinedRefs("""
        refs/remotes/origin/master\t2026-05-10T12:30:00-05:00\t\t

        """)

        #expect(snapshot.defaultBranch == "master")
    }

    @MainActor
    @Test("""
    @spec PERF-1.9: When remote-branch polling scans more than four repositories, the application shall dispatch at most four repositories per ten-second tick and rotate fairly so twelve repositories require three ticks rather than twelve scans on every tick.
    """)
    func pollingBatchesAndRotatesAcrossRepositories() async throws {
        let lister = ConcurrencyRecordingRemoteBranchLister(delay: .milliseconds(100))
        let ticker = CapturingTicker()
        let store = RemoteBranchStore(list: lister.list)
        let repos = (0..<12).map {
            RepoEntry(path: "/repo-\($0)", displayName: "repo-\($0)", worktrees: [])
        }

        store.start(ticker: ticker, getRepos: { repos })

        for expectedCompletedCount in [4, 8, 12] {
            await ticker.fire()
            let dispatchedCount = repos.filter {
                store.isInFlightForTesting($0.path)
            }.count
            try #require(dispatchedCount == 4)
            try await waitUntil(timeout: 3.0) {
                lister.completedCount == expectedCompletedCount
            }
        }

        #expect(lister.calledPaths == Set(repos.map(\.path)))
        #expect(lister.maximumConcurrentCount <= 4)
    }

    @MainActor
    @Test("@spec GIT-2.8: While repositories are in the sidebar, the application shall scan local `refs/remotes/origin/*` for at most four repositories per ten-second tick without contacting the network and advance a round-robin cursor so every repository is scanned within `ceil(repoCount / 4)` ticks. The scan shall maintain repo-scoped locally-known remote branch names and shall not replace the repo-level fetch cadence that discovers branches created from another clone.")
    func recurringPollBatchesLocalRefScansWithoutNetwork() async throws {
        let executor = CombinedRefScanExecutor()
        let store = RemoteBranchStore(
            list: RemoteBranchStore.makeDefaultList(executor: executor)
        )
        let ticker = CapturingTicker()
        let repos = (0..<5).map {
            RepoEntry(path: "/repo-\($0)", displayName: "repo-\($0)", worktrees: [])
        }
        store.start(ticker: ticker, getRepos: { repos })

        await ticker.fire()
        try await waitUntil(timeout: 1.0) {
            executor.invocations.count == 4
                && store.branchesByRepo.count == 4
        }
        await ticker.fire()
        try await waitUntil(timeout: 1.0) {
            executor.invocations.count == 8
                && store.branchesByRepo.count == 5
        }

        let invocations = executor.invocations
        #expect(Set(invocations.map(\.directory)) == Set(repos.map(\.path)))
        #expect(invocations.allSatisfy {
            $0.command == "git"
                && $0.args.first == "for-each-ref"
                && !$0.args.contains("fetch")
        })
        #expect(repos.allSatisfy {
            store.hasRemote(repoPath: $0.path, branch: "main")
        })
    }

    @MainActor
    @Test func upstreamRemoteBranchExposesTrackedMapping() async throws {
        let store = RemoteBranchStore(list: { _ in
            RemoteBranchSnapshot(
                branches: ["main", "feature/bar"],
                upstreams: ["main": "main", "local-name": "feature/bar"]
            )
        })
        store.refresh(repoPath: "/repo")
        try await waitUntil(timeout: 1.0) {
            store.hasRemote(repoPath: "/repo", branch: "local-name")
        }

        #expect(store.upstreamRemoteBranch(repoPath: "/repo", branch: "main") == "main")
        #expect(store.upstreamRemoteBranch(repoPath: "/repo", branch: "local-name") == "feature/bar")
        #expect(store.upstreamRemoteBranch(repoPath: "/repo", branch: "unknown") == nil)
    }

    @MainActor
    @Test func hasRemoteIsTrueWhenUpstreamSetEvenIfLocalNameNotInBranches() async throws {
        let store = RemoteBranchStore(list: { _ in
            RemoteBranchSnapshot(
                branches: ["feature/bar"],
                upstreams: ["local-rename": "feature/bar"]
            )
        })
        store.refresh(repoPath: "/repo")
        try await waitUntil(timeout: 1.0) {
            store.hasRemote(repoPath: "/repo", branch: "local-rename")
        }
        #expect(store.hasRemote(repoPath: "/repo", branch: "local-rename"))
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
        let store = RemoteBranchStore(list: { _ in RemoteBranchSnapshot(branches: ["main"]) })
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
        let store = RemoteBranchStore(list: { _ in RemoteBranchSnapshot(branches: ["main"]) })
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
    @Test func clearSkipsARefreshStillWaitingForAPermit() async throws {
        let limiter = BackgroundProcessLimiter(capacity: 1)
        let blocker = PermitBlocker()
        let occupyingTask = Task {
            await limiter.run {
                await blocker.wait()
            }
        }
        try await waitUntil(timeout: 1.0) { blocker.isWaiting }

        let lister = RecordingRemoteBranchLister(results: [
            "/repo": .success(["main"]),
        ])
        let store = RemoteBranchStore(
            list: lister.list,
            backgroundProcessLimiter: limiter
        )
        var completionRan = false

        store.refresh(repoPath: "/repo") {
            completionRan = true
        }
        try await Task.sleep(for: .milliseconds(50))
        store.clear(repoPath: "/repo")
        blocker.resume()
        await occupyingTask.value

        try await waitUntil(timeout: 1.0) { completionRan }
        #expect(lister.invocationCount(for: "/repo") == 0)
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
            secondCompletionSnapshot = store.branchesByRepo["/repo"]?.branches
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
        let store = RemoteBranchStore(list: { _ in RemoteBranchSnapshot(branches: []) })

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

private final class RemoteBranchTimeoutRecordingExecutor: CLIExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var timeouts: [Duration?] = []

    var recordedInvocations: [Duration?] {
        lock.withLock { timeouts }
    }

    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory, timeout: nil)
    }

    func run(
        command: String,
        args: [String],
        at directory: String,
        timeout: Duration?
    ) async throws -> CLIOutput {
        record(timeout)
        return CLIOutput(stdout: "", stderr: "", exitCode: 0)
    }

    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await capture(command: command, args: args, at: directory, timeout: nil)
    }

    func capture(
        command: String,
        args: [String],
        at directory: String,
        timeout: Duration?
    ) async throws -> CLIOutput {
        record(timeout)
        return CLIOutput(stdout: "origin/main\n", stderr: "", exitCode: 0)
    }

    private func record(_ timeout: Duration?) {
        lock.withLock {
            timeouts.append(timeout)
        }
    }
}

private final class CombinedRefScanExecutor: CLIExecutor, @unchecked Sendable {
    struct Invocation: Sendable {
        let command: String
        let args: [String]
        let directory: String
    }

    private let lock = NSLock()
    private var _invocations: [Invocation] = []

    var invocationCount: Int {
        lock.withLock { _invocations.count }
    }

    var invocations: [Invocation] {
        lock.withLock { _invocations }
    }

    private let output = """
    refs/heads/feature/local\t2026-05-13T09:15:00-05:00\trefs/remotes/origin/feature/remote\t
    refs/heads/main\t2026-05-10T12:30:00-05:00\trefs/remotes/origin/main\t
    refs/heads/non-origin\t2026-05-09T12:30:00-05:00\trefs/remotes/upstream/main\t
    refs/remotes/origin/HEAD\t2026-05-10T12:30:00-05:00\t\trefs/remotes/origin/main
    refs/remotes/origin/feature/remote\t2026-05-13T09:15:00-05:00\t\t
    refs/remotes/origin/main\t2026-05-10T12:30:00-05:00\t\t

    """

    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory, timeout: nil)
    }

    func run(
        command: String,
        args: [String],
        at directory: String,
        timeout: Duration?
    ) async throws -> CLIOutput {
        recordInvocation(command: command, args: args, directory: directory)
        return CLIOutput(stdout: output, stderr: "", exitCode: 0)
    }

    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await capture(command: command, args: args, at: directory, timeout: nil)
    }

    func capture(
        command: String,
        args: [String],
        at directory: String,
        timeout: Duration?
    ) async throws -> CLIOutput {
        recordInvocation(command: command, args: args, directory: directory)
        return CLIOutput(stdout: output, stderr: "", exitCode: 0)
    }

    private func recordInvocation(
        command: String,
        args: [String],
        directory: String
    ) {
        lock.withLock {
            _invocations.append(Invocation(
                command: command,
                args: args,
                directory: directory
            ))
        }
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

private final class PermitBlocker: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool {
        lock.withLock { continuation != nil }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
            }
        }
    }

    func resume() {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private extension ISO8601DateFormatter {
    static func dateFromInternetDateTime(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

private final class RecordingRemoteBranchLister: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: Result<Set<String>, Error>]
    private var invocations: [String: Int] = [:]
    private var continuations: [(Result<RemoteBranchSnapshot, Error>, CheckedContinuation<RemoteBranchSnapshot, Error>)] = []
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
            guard let self else { return RemoteBranchSnapshot(branches: []) }
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
            case .success(let snapshot):
                continuation.resume(returning: snapshot)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private func list(repoPath: String) async throws -> RemoteBranchSnapshot {
        let result: Result<RemoteBranchSnapshot, Error> = lock.withLock {
            invocations[repoPath, default: 0] += 1
            switch results[repoPath] ?? .success([]) {
            case .success(let branches):
                return .success(RemoteBranchSnapshot(branches: branches))
            case .failure(let error):
                return .failure(error)
            }
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

private final class ConcurrencyRecordingRemoteBranchLister: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: Duration
    private var activeCount = 0
    private var _completedCount = 0
    private var _maximumConcurrentCount = 0
    private var _calledPaths: Set<String> = []

    init(delay: Duration) {
        self.delay = delay
    }

    var completedCount: Int {
        lock.withLock { _completedCount }
    }

    var maximumConcurrentCount: Int {
        lock.withLock { _maximumConcurrentCount }
    }

    var calledPaths: Set<String> {
        lock.withLock { _calledPaths }
    }

    var list: RemoteBranchStore.ListFunction {
        { [weak self] repoPath in
            guard let self else { return RemoteBranchSnapshot() }
            self.recordStart(repoPath: repoPath)
            try await Task.sleep(for: self.delay)
            self.recordCompletion()
            return RemoteBranchSnapshot()
        }
    }

    private func recordStart(repoPath: String) {
        lock.withLock {
            activeCount += 1
            _maximumConcurrentCount = max(_maximumConcurrentCount, activeCount)
            _calledPaths.insert(repoPath)
        }
    }

    private func recordCompletion() {
        lock.withLock {
            activeCount -= 1
            _completedCount += 1
        }
    }
}
