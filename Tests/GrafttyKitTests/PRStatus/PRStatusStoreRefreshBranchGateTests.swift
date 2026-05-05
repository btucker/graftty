import Testing
import Foundation
@testable import GrafttyKit

/// Refresh paths must skip git sentinel branches (`(detached)` etc.)
/// and must avoid host detection / fetch when no remote branch
/// exists locally — the on-demand callers (sidebar selection,
/// `branchDidChange` from a HEAD-change event) need the same
/// gates the polling tick uses (`PR-7.5`).
@Suite("PRStatusStore — refresh fetchable-branch gate", .serialized)
struct PRStatusStoreRefreshBranchGateTests {

    /// Counts `fetch` calls so we can verify the gate is respected.
    actor CountingFetcher: PRFetcher {
        private(set) var fetchCount = 0
        func fetch(
            origin: HostingOrigin,
            branchesOfInterest: Set<String>
        ) async throws -> RepoPRSnapshot {
            fetchCount += 1
            return RepoPRSnapshot(prsByBranch: [:])
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
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(!store.isInFlightForTesting("/r"), "sentinel branch must not enter inFlight")
        #expect(await fetcher.fetchCount == 0, "no `gh` invocations for sentinel branches")
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
        for _ in 0..<20 {
            if await fetcher.fetchCount > 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(await fetcher.fetchCount == 1, "real branches are still fetched")
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
        let ticker = ManualTicker()
        let repo = RepoEntry(
            path: "/repo",
            displayName: "repo",
            worktrees: [WorktreeEntry(path: "/wt", branch: "feature", state: .running)]
        )
        store.start(ticker: ticker, getRepos: { [repo] })
        defer { store.stop() }

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
        let ticker = ManualTicker()
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
            worktrees: [WorktreeEntry(path: "/repo/wt", branch: "feature", state: .running)]
        )

        store.start(ticker: ticker, getRepos: { [repo] })
        defer { store.stop() }

        await ticker.fire()
        try await Task.sleep(for: .milliseconds(100))
        // Without a remote branch the per-repo fetch may run, but
        // the snapshot won't include `feature` and the worktree is
        // marked locally-unpushed (no info, not absent).
        #expect(store.infos["/repo/wt"] == nil)

        await lister.set(branches: ["feature"])
        remoteBranchStore.refresh(repoPath: "/repo")
        try await waitUntil(timeout: 5.0) {
            remoteBranchStore.hasRemote(repoPath: "/repo", branch: "feature")
        }

        // Step past both the in-flight window and the cadence
        // interval, then re-tick. Without seeding `lastFetch` here,
        // the non-forced tick is suppressed by the cadence guard
        // because the first tick set `lastFetch` to "now".
        let past = Date().addingTimeInterval(-3600)
        store.seedInFlightSinceForTesting(past, forRepo: "/repo")
        store.seedLastFetchForTesting(past, forRepo: "/repo")
        await ticker.fire()

        try await waitUntil(timeout: 10.0) {
            store.infos["/repo/wt"]?.number == 77
        }
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
        let ticker = ManualTicker()
        let repo = RepoEntry(
            path: "/repo",
            displayName: "repo",
            worktrees: [WorktreeEntry(path: "/wt", branch: "feature", state: .running)]
        )
        store.start(ticker: ticker, getRepos: { [repo] })
        defer { store.stop() }

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

    func fetch(
        origin: HostingOrigin,
        branchesOfInterest: Set<String>
    ) async throws -> RepoPRSnapshot {
        invocations += 1
        guard let response else { return RepoPRSnapshot(prsByBranch: [:]) }
        // Map response to the only branch the gate tests care about.
        var byBranch: [String: PRInfo] = [:]
        if let branch = branchesOfInterest.first {
            byBranch[branch] = response
        } else {
            byBranch["feature"] = response
        }
        return RepoPRSnapshot(prsByBranch: byBranch)
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


private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        value += 1
    }

    func current() -> Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
