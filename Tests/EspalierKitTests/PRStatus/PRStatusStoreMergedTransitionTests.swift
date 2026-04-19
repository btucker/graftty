import Testing
import Foundation
@testable import EspalierKit

@Suite("PRStatusStore merged-transition callback")
struct PRStatusStoreMergedTransitionTests {

    /// Programmable fetcher — returns whatever `response` holds at the
    /// moment `fetch` is called, and bumps an invocation counter so
    /// tests can assert the store didn't collapse multiple refreshes
    /// into a single call. Built as an actor so it satisfies `Sendable`
    /// for the store's `fetcherFor` closure and stays legal under Swift
    /// 6 concurrency checking.
    actor ScriptedFetcher: PRFetcher {
        private var _response: PRInfo?
        private(set) var invocations = 0

        init(initial: PRInfo? = nil) { self._response = initial }

        func setResponse(_ r: PRInfo?) { _response = r }

        func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo? {
            invocations += 1
            return _response
        }
    }

    /// Collects `(worktreePath, prNumber)` fires so tests can assert
    /// both count and arguments.
    actor EventSink {
        private(set) var events: [(String, Int)] = []
        func record(_ path: String, _ number: Int) { events.append((path, number)) }
        func count() -> Int { events.count }
    }

    private static let origin = HostingOrigin(
        provider: .github, host: "github.com", owner: "foo", repo: "bar"
    )

    private static func makeStore(fetcher: PRFetcher) async -> PRStatusStore {
        await PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in origin }
        )
    }

    private static func pr(number: Int, state: PRInfo.State) -> PRInfo {
        PRInfo(
            number: number,
            title: "pr-\(number)",
            url: URL(string: "https://github.com/foo/bar/pull/\(number)")!,
            state: state,
            checks: PRInfo.Checks.none,
            fetchedAt: Date()
        )
    }

    /// Wait until `store.infos[path]` passes `predicate`, polling at
    /// 50ms up to ~2.5s. Returns whatever the final value is so the
    /// test can assert on it without an extra read.
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
        let fetcher = ScriptedFetcher(initial: Self.pr(number: 42, state: .merged))
        let store = await Self.makeStore(fetcher: fetcher)
        let sink = EventSink()
        await MainActor.run {
            store.onPRMerged = { path, num in
                Task { await sink.record(path, num) }
            }
        }

        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        _ = try await Self.waitForInfo(store: store, path: "/wt") { $0?.number == 42 }

        // The callback schedules a Task onto the actor; yield until it lands.
        for _ in 0..<20 where await sink.count() == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let events = await sink.events
        #expect(events.count == 1)
        #expect(events.first?.0 == "/wt")
        #expect(events.first?.1 == 42)
    }

    @Test func firesOnOpenToMergedTransition() async throws {
        let fetcher = ScriptedFetcher(initial: Self.pr(number: 7, state: .open))
        let store = await Self.makeStore(fetcher: fetcher)
        let sink = EventSink()
        await MainActor.run {
            store.onPRMerged = { path, num in
                Task { await sink.record(path, num) }
            }
        }

        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        _ = try await Self.waitForInfo(store: store, path: "/wt") { $0?.state == .open }
        #expect(await sink.count() == 0, "open fetch must not fire the merged callback")

        // Server-side merge flips the fetcher's response.
        await fetcher.setResponse(Self.pr(number: 7, state: .merged))
        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        _ = try await Self.waitForInfo(store: store, path: "/wt") { $0?.state == .merged }

        for _ in 0..<20 where await sink.count() == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let events = await sink.events
        #expect(events.count == 1)
        #expect(events.first?.1 == 7)
    }

    @Test func doesNotReFireForIdempotentMergedRefetch() async throws {
        let fetcher = ScriptedFetcher(initial: Self.pr(number: 99, state: .merged))
        let store = await Self.makeStore(fetcher: fetcher)
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

        // A second refresh with the same merged PR is the normal polling
        // steady state. The callback must NOT re-fire — otherwise the
        // offer dialog would pop up every 15 minutes forever.
        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        _ = try await Self.waitForInfo(store: store, path: "/wt") { $0?.state == .merged }
        // Give any spurious callback time to land before asserting.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await sink.count() == 1, "merged→merged for same PR must not re-fire")
    }

    @Test func firesAgainForDifferentMergedPRNumber() async throws {
        // Rare but possible: the branch's merged PR is closed and a
        // fresh PR is opened and merged. `gh pr list --state merged`
        // starts returning the new number. The store should treat that
        // as a new transition.
        let fetcher = ScriptedFetcher(initial: Self.pr(number: 1, state: .merged))
        let store = await Self.makeStore(fetcher: fetcher)
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

        await fetcher.setResponse(Self.pr(number: 2, state: .merged))
        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        _ = try await Self.waitForInfo(store: store, path: "/wt") { $0?.number == 2 }
        for _ in 0..<20 where await sink.count() < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let events = await sink.events
        #expect(events.count == 2)
        #expect(events.map(\.1) == [1, 2])
    }
}
