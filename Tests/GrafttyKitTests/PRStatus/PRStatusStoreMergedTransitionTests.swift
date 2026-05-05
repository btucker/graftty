import Testing
import Foundation
@testable import GrafttyKit

@Suite("PRStatusStore merged-transition callback")
struct PRStatusStoreMergedTransitionTests {

    /// Programmable fetcher — returns whatever snapshot is set at
    /// the moment `fetch` is called, and bumps an invocation
    /// counter so tests can assert the store didn't collapse
    /// multiple refreshes into a single call. Built as an actor so
    /// it satisfies `Sendable` for the store's `fetcherFor` closure.
    actor ScriptedFetcher: PRFetcher {
        private var snapshot: RepoPRSnapshot
        private(set) var invocations = 0

        init(initial: RepoPRSnapshot = RepoPRSnapshot(prsByBranch: [:])) {
            self.snapshot = initial
        }

        func setSnapshot(_ snap: RepoPRSnapshot) { snapshot = snap }

        func fetch(
            origin: HostingOrigin,
            branchesOfInterest: Set<String>
        ) async throws -> RepoPRSnapshot {
            invocations += 1
            return snapshot
        }
    }

    /// Collects `(worktreePath, prNumber)` fires so tests can
    /// assert both count and arguments.
    actor EventSink {
        private(set) var events: [(String, Int)] = []
        func record(_ path: String, _ number: Int) { events.append((path, number)) }
        func count() -> Int { events.count }
    }

    private static let origin = HostingOrigin(
        provider: .github, host: "github.com", owner: "foo", repo: "bar"
    )

    @MainActor
    private static func makeStore(fetcher: PRFetcher) -> (PRStatusStore, ManualTicker) {
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
        return (store, ticker)
    }

    private static func snapshot(number: Int, state: PRInfo.State) -> RepoPRSnapshot {
        RepoPRSnapshot(prsByBranch: [
            "feat": PRInfo(
                number: number,
                title: "pr-\(number)",
                url: URL(string: "https://github.com/foo/bar/pull/\(number)")!,
                state: state,
                checks: PRInfo.Checks.none,
                fetchedAt: Date()
            )
        ])
    }

    /// Force the store past its 30s in-flight cap so a second
    /// refresh dispatch isn't suppressed.
    @MainActor
    private static func clearInFlight(_ store: PRStatusStore) {
        store.seedInFlightSinceForTesting(
            Date().addingTimeInterval(-3600),
            forRepo: "/repo"
        )
    }

    private static func waitForInfo(
        store: PRStatusStore,
        path: String,
        where predicate: @escaping @Sendable (PRInfo?) -> Bool
    ) async throws -> PRInfo? {
        for _ in 0..<50 {
            if await predicate(store.infos[path]) {
                return await store.infos[path]
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return await store.infos[path]
    }

    @Test func firesOnNilToMergedTransition() async throws {
        let fetcher = ScriptedFetcher(initial: Self.snapshot(number: 42, state: .merged))
        let (store, _) = await Self.makeStore(fetcher: fetcher)
        let sink = EventSink()
        await MainActor.run {
            store.onPRMerged = { path, num in
                Task { await sink.record(path, num) }
            }
        }

        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        _ = try await Self.waitForInfo(store: store, path: "/wt") { $0?.number == 42 }

        for _ in 0..<20 where await sink.count() == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let events = await sink.events
        #expect(events.count == 1)
        #expect(events.first?.0 == "/wt")
        #expect(events.first?.1 == 42)
        await MainActor.run { store.stop() }
    }

    @Test func firesOnOpenToMergedTransition() async throws {
        let fetcher = ScriptedFetcher(initial: Self.snapshot(number: 7, state: .open))
        let (store, _) = await Self.makeStore(fetcher: fetcher)
        let sink = EventSink()
        await MainActor.run {
            store.onPRMerged = { path, num in
                Task { await sink.record(path, num) }
            }
        }

        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        _ = try await Self.waitForInfo(store: store, path: "/wt") { $0?.state == .open }
        #expect(await sink.count() == 0, "open fetch must not fire the merged callback")

        await fetcher.setSnapshot(Self.snapshot(number: 7, state: .merged))
        await MainActor.run { Self.clearInFlight(store) }
        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        _ = try await Self.waitForInfo(store: store, path: "/wt") { $0?.state == .merged }

        for _ in 0..<20 where await sink.count() == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let events = await sink.events
        #expect(events.count == 1)
        #expect(events.first?.1 == 7)
        await MainActor.run { store.stop() }
    }

    @Test func doesNotReFireForIdempotentMergedRefetch() async throws {
        let fetcher = ScriptedFetcher(initial: Self.snapshot(number: 99, state: .merged))
        let (store, _) = await Self.makeStore(fetcher: fetcher)
        let sink = EventSink()
        await MainActor.run {
            store.onPRMerged = { path, num in
                Task { await sink.record(path, num) }
            }
        }

        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        _ = try await Self.waitForInfo(store: store, path: "/wt") { $0?.state == .merged }
        for _ in 0..<20 where await sink.count() == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await sink.count() == 1)

        await MainActor.run { Self.clearInFlight(store) }
        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        _ = try await Self.waitForInfo(store: store, path: "/wt") { $0?.state == .merged }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await sink.count() == 1, "merged→merged for same PR must not re-fire")
        await MainActor.run { store.stop() }
    }

    @Test func firesAgainForDifferentMergedPRNumber() async throws {
        let fetcher = ScriptedFetcher(initial: Self.snapshot(number: 1, state: .merged))
        let (store, _) = await Self.makeStore(fetcher: fetcher)
        let sink = EventSink()
        await MainActor.run {
            store.onPRMerged = { path, num in
                Task { await sink.record(path, num) }
            }
        }

        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        _ = try await Self.waitForInfo(store: store, path: "/wt") { $0?.number == 1 }
        for _ in 0..<20 where await sink.count() == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await sink.count() == 1)

        await fetcher.setSnapshot(Self.snapshot(number: 2, state: .merged))
        await MainActor.run { Self.clearInFlight(store) }
        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        _ = try await Self.waitForInfo(store: store, path: "/wt") { $0?.number == 2 }
        for _ in 0..<20 where await sink.count() < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let events = await sink.events
        #expect(events.count == 2)
        #expect(events.map(\.1) == [1, 2])
        await MainActor.run { store.stop() }
    }
}

