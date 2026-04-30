import Testing
import Foundation
@testable import GrafttyKit

/// The polling loop already skips worktrees whose `branch` is a git
/// sentinel like `(detached)` (see PRStatusStore+Poller's pick loop).
/// The on-demand callers — MainWindow's select-worktree refresh and
/// `branchDidChange` from a HEAD-change event — did not, meaning a
/// detached-HEAD worktree still fired two wasted `gh pr list` calls
/// per selection / HEAD change. PR-7.5.
@Suite("PRStatusStore — refresh fetchable-branch gate")
struct PRStatusStoreRefreshBranchGateTests {

    /// Counts `fetch` calls so we can verify the gate is respected.
    final class CountingFetcher: PRFetcher, @unchecked Sendable {
        var fetchCount: Int = 0
        func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo? {
            fetchCount += 1
            return nil
        }
    }

    @MainActor
    @Test func refreshWithSentinelBranchIsNoOp() async {
        let fetcher = CountingFetcher()
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in HostingOrigin(provider: .github, host: "github.com", owner: "o", repo: "r") }
        )

        store.refresh(worktreePath: "/wt", repoPath: "/r", branch: "(detached)")
        // Give any accidentally-spawned Task a chance to run to completion.
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(!store.isInFlightForTesting("/wt"), "sentinel branch must not enter inFlight")
        #expect(fetcher.fetchCount == 0, "no `gh` invocations for sentinel branches")
    }

    @MainActor
    @Test func branchDidChangeToSentinelDoesNotFetch() async {
        let fetcher = CountingFetcher()
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in HostingOrigin(provider: .github, host: "github.com", owner: "o", repo: "r") }
        )

        // Precondition: the worktree already had some cached state.
        store.beginInFlightForTesting("/wt")
        #expect(store.isInFlightForTesting("/wt"))

        store.branchDidChange(worktreePath: "/wt", repoPath: "/r", branch: "(detached)")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(!store.isInFlightForTesting("/wt"), "branchDidChange → sentinel must release inFlight")
        #expect(fetcher.fetchCount == 0, "branchDidChange → sentinel must not fetch")
    }

    @MainActor
    @Test func refreshWithRealBranchStillFetches() async {
        let fetcher = CountingFetcher()
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in HostingOrigin(provider: .github, host: "github.com", owner: "o", repo: "r") }
        )

        store.refresh(worktreePath: "/wt", repoPath: "/r", branch: "main")
        // Wait for the spawned Task to run to completion.
        for _ in 0..<20 {
            if fetcher.fetchCount > 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(fetcher.fetchCount == 1, "real branches are still fetched")
    }

    @MainActor
    @Test func refreshWithoutLocalRemoteBranchDoesNotDetectHostOrFetch() async throws {
        let remoteBranchStore = RemoteBranchStore(list: { _ in [] })
        let detectCount = LockedCounter()
        let fetcher = RemoteGateCountingFetcher(response: nil)
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in
                detectCount.increment()
                return Self.origin
            },
            remoteBranchStore: remoteBranchStore
        )

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feature")
        try await Task.sleep(for: .milliseconds(100))

        #expect(detectCount.current() == 0, "local-only branches must not resolve host providers")
        #expect(await fetcher.invocations == 0, "local-only branches must not fetch PR status")
        #expect(store.infos["/wt"] == nil)
        #expect(!store.absent.contains("/wt"))
    }

    @MainActor
    @Test func refreshWithLocalRemoteBranchFetchesPRStatus() async throws {
        let remoteBranchStore = RemoteBranchStore(list: { _ in ["feature"] })
        remoteBranchStore.refresh(repoPath: "/repo")
        try await waitUntil(timeout: 1.0) {
            remoteBranchStore.hasRemote(repoPath: "/repo", branch: "feature")
        }

        let detectCount = LockedCounter()
        let fetcher = RemoteGateCountingFetcher(response: Self.pr(number: 42))
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in
                detectCount.increment()
                return Self.origin
            },
            remoteBranchStore: remoteBranchStore
        )

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feature")

        try await waitUntil(timeout: 1.0) {
            await fetcher.invocations == 1
        }
        #expect(detectCount.current() == 1)
        #expect(store.infos["/wt"]?.number == 42)
    }

    @MainActor
    @Test func tickStartsPollingAfterLocalRemoteBranchAppears() async throws {
        let lister = MutableRemoteBranchLister(branches: [])
        let remoteBranchStore = RemoteBranchStore(list: { repoPath in
            try await lister.list(repoPath: repoPath)
        })
        let ticker = RemoteGateTicker()
        let fetcher = RemoteGateCountingFetcher(response: Self.pr(number: 77))
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in Self.origin },
            remoteBranchStore: remoteBranchStore
        )
        let repo = RepoEntry(
            path: "/repo",
            displayName: "repo",
            worktrees: [WorktreeEntry(path: "/repo/wt", branch: "feature")]
        )

        store.start(ticker: ticker, getRepos: { [repo] })
        defer { store.stop() }

        await ticker.fire()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fetcher.invocations == 0)

        await lister.set(branches: ["feature"])
        remoteBranchStore.refresh(repoPath: "/repo")
        try await waitUntil(timeout: 1.0) {
            remoteBranchStore.hasRemote(repoPath: "/repo", branch: "feature")
        }

        await ticker.fire()

        try await waitUntil(timeout: 1.0) {
            await fetcher.invocations == 1
        }
        #expect(store.infos["/repo/wt"]?.number == 77)
    }

    @MainActor
    @Test func refreshWithoutLocalRemoteBranchClearsCachedStatus() async throws {
        let lister = MutableRemoteBranchLister(branches: ["feature"])
        let remoteBranchStore = RemoteBranchStore(list: { repoPath in
            try await lister.list(repoPath: repoPath)
        })
        remoteBranchStore.refresh(repoPath: "/repo")
        try await waitUntil(timeout: 1.0) {
            remoteBranchStore.hasRemote(repoPath: "/repo", branch: "feature")
        }

        let fetcher = RemoteGateCountingFetcher(response: Self.pr(number: 99))
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in Self.origin },
            remoteBranchStore: remoteBranchStore
        )

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feature")
        try await waitUntil(timeout: 1.0) {
            await fetcher.invocations == 1
        }
        #expect(store.infos["/wt"]?.number == 99)

        await lister.set(branches: [])
        remoteBranchStore.refresh(repoPath: "/repo")
        try await waitUntil(timeout: 1.0) {
            !remoteBranchStore.hasRemote(repoPath: "/repo", branch: "feature")
        }

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feature")
        try await Task.sleep(for: .milliseconds(100))

        #expect(await fetcher.invocations == 1)
        #expect(store.infos["/wt"] == nil)
        #expect(!store.absent.contains("/wt"))
    }

    private static let origin = HostingOrigin(
        provider: .github,
        host: "github.com",
        owner: "foo",
        repo: "bar"
    )

    private static func pr(number: Int) -> PRInfo {
        PRInfo(
            number: number,
            title: "PR \(number)",
            url: URL(string: "https://github.com/foo/bar/pull/\(number)")!,
            state: .open,
            checks: .none,
            fetchedAt: Date()
        )
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        let succeeded = await condition()
        #expect(succeeded, "waitUntil timed out")
    }
}

private actor RemoteGateCountingFetcher: PRFetcher {
    private(set) var invocations = 0
    private let response: PRInfo?

    init(response: PRInfo?) {
        self.response = response
    }

    func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo? {
        invocations += 1
        return response
    }
}

private actor MutableRemoteBranchLister {
    private var branches: Set<String>

    init(branches: Set<String>) {
        self.branches = branches
    }

    func set(branches: Set<String>) {
        self.branches = branches
    }

    func list(repoPath: String) async throws -> Set<String> {
        branches
    }
}

@MainActor
private final class RemoteGateTicker: PollingTickerLike {
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
