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
            completions.count == 2
        }
        #expect(completions == ["first", "second"])
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
        await #expect(condition(), "waitUntil timed out")
    }
}

private enum TestError: Error {
    case boom
}

private final class RecordingRemoteBranchLister: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: Result<Set<String>, Error>]
    private var invocations: [String: Int] = [:]
    private var continuations: [CheckedContinuation<Set<String>, Error>] = []
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

        for continuation in pending {
            continuation.resume(returning: ["main"])
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
                    continuations.append(continuation)
                }
            }
        }

        return try result.get()
    }
}
