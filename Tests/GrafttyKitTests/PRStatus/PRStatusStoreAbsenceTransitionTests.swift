import XCTest
import GrafttyProtocol
@testable import GrafttyKit

/// @spec PR-8.24: While polling a tracked PR or MR, the application shall
/// preserve raw `checks == .none` and `mergeable == .unknown` values for the
/// UI but shall retain only meaningful checks and mergeability conclusions as
/// notification baselines. When a meaningful conclusion follows transient
/// absence for the same PR identity, the application shall notify only if it
/// differs from the last meaningful conclusion. When the PR disappears, the
/// worktree cache is cleared, or PR identity changes, the application shall
/// seed a new baseline without comparing distinct PR observations.
@MainActor
final class PRStatusStoreAbsenceTransitionTests: XCTestCase {
    private struct CapturedTransition {
        let event: RoutableEvent
        let attrs: [String: String]
    }

    private static let origin = HostingOrigin(
        provider: .github, host: "github.com", owner: "acme", repo: "web"
    )
    private static let repoPath = "/repo"
    private static let worktreePath = "/wt/a"
    private static let branch = "feature"

    private func info(
        number: Int = 5,
        url: URL? = nil,
        checks: PRInfo.Checks,
        mergeable: PRInfo.Mergeable = .unknown,
        state: PRInfo.State = .open
    ) -> PRInfo {
        PRInfo(
            number: number,
            title: "PR \(number)",
            url: url ?? URL(string: "https://github.com/acme/web/pull/\(number)")!,
            state: state,
            checks: checks,
            mergeable: mergeable,
            fetchedAt: Date()
        )
    }

    private func makeStore(
        snapshots: [RepoPRSnapshot]
    ) -> (store: PRStatusStore, fetcher: SequencedPRFetcher) {
        let fetcher = SequencedPRFetcher(snapshots: snapshots)
        let origin = Self.origin
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in origin }
        )
        let repo = RepoEntry(
            path: Self.repoPath,
            displayName: "repo",
            worktrees: [
                WorktreeEntry(
                    path: Self.worktreePath,
                    branch: Self.branch,
                    state: .running
                )
            ]
        )
        store.start(ticker: ManualTicker(), getRepos: { [repo] })
        return (store, fetcher)
    }

    private func snapshot(_ info: PRInfo?) -> RepoPRSnapshot {
        RepoPRSnapshot(
            prsByBranch: info.map { [Self.branch: $0] } ?? [:]
        )
    }

    private func refresh(
        _ store: PRStatusStore,
        fetcher: SequencedPRFetcher,
        expectedFetchCount: Int
    ) async throws {
        store.refresh(
            worktreePath: Self.worktreePath,
            repoPath: Self.repoPath,
            branch: Self.branch
        )

        for _ in 0..<200 {
            if await fetcher.fetchCount >= expectedFetchCount,
               !store.isInFlightForTesting(Self.repoPath) {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("fetch \(expectedFetchCount) did not finish")
    }

    /// Bug A: a run heading to green briefly reports an empty / all-neutral
    /// rollup (`.none`) between the pending phase and the success phase.
    /// `pending → none` must not fire `ciConclusionChanged`.
    func testChecksPendingToNoneDoesNotFire() {
        let store = PRStatusStore()
        var events: [RoutableEvent] = []
        store.onTransition = { event, _, _ in events.append(event) }

        store.detectAndFireTransitionsForTesting(
            worktreePath: "/wt/a",
            previous: info(checks: .pending, mergeable: .mergeable),
            current: info(checks: .none, mergeable: .mergeable),
            origin: Self.origin
        )
        XCTAssertEqual(events, [], "pending → none is a transient, not a CI conclusion")
    }

    /// Bug B: GitHub reports `mergeable: UNKNOWN` transiently while it
    /// recomputes mergeability. `mergeable → unknown` must not fire
    /// `mergabilityChanged`.
    func testMergeableToUnknownDoesNotFire() {
        let store = PRStatusStore()
        var events: [RoutableEvent] = []
        store.onTransition = { event, _, _ in events.append(event) }

        store.detectAndFireTransitionsForTesting(
            worktreePath: "/wt/a",
            previous: info(checks: .success, mergeable: .mergeable),
            current: info(checks: .success, mergeable: .unknown),
            origin: Self.origin
        )
        XCTAssertEqual(events, [], "mergeable → unknown is GitHub recomputing, not a real change")
    }

    /// A direct absence observation has no meaningful conclusion to
    /// compare against, so the first meaningful value seeds rather than
    /// claiming a change.
    func testFirstMeaningfulValuesAfterInitialAbsenceSeedWithoutFiring() {
        let store = PRStatusStore()
        var events: [RoutableEvent] = []
        store.onTransition = { event, _, _ in events.append(event) }

        // none → success seeds the first meaningful CI conclusion.
        store.detectAndFireTransitionsForTesting(
            worktreePath: "/wt/a",
            previous: info(checks: .none, mergeable: .mergeable),
            current: info(checks: .success, mergeable: .mergeable),
            origin: Self.origin
        )
        XCTAssertEqual(events, [])

        // unknown → conflicting also seeds the first meaningful verdict.
        events.removeAll()
        store.detectAndFireTransitionsForTesting(
            worktreePath: "/wt/a",
            previous: info(checks: .success, mergeable: .unknown),
            current: info(checks: .success, mergeable: .conflicting),
            origin: Self.origin
        )
        XCTAssertEqual(events, [])
    }

    func testTransientMergeabilityAbsenceDoesNotReannounceSameVerdict() async throws {
        let mergeable = info(checks: .success, mergeable: .mergeable)
        let unknown = info(checks: .success, mergeable: .unknown)
        let harness = makeStore(snapshots: [
            snapshot(mergeable),
            snapshot(unknown),
            snapshot(mergeable),
        ])
        defer { harness.store.stop() }
        var events: [CapturedTransition] = []
        harness.store.onTransition = { event, _, attrs in
            events.append(CapturedTransition(event: event, attrs: attrs))
        }

        try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: 1)
        try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: 2)
        XCTAssertEqual(harness.store.infos[Self.worktreePath]?.mergeable, .unknown)
        try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: 3)

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(harness.store.infos[Self.worktreePath]?.mergeable, .mergeable)
    }

    func testMeaningfulMergeabilityChangeAfterAbsenceUsesLastMeaningfulVerdict() async throws {
        let harness = makeStore(snapshots: [
            snapshot(info(checks: .success, mergeable: .mergeable)),
            snapshot(info(checks: .success, mergeable: .unknown)),
            snapshot(info(checks: .success, mergeable: .conflicting)),
        ])
        defer { harness.store.stop() }
        var events: [CapturedTransition] = []
        harness.store.onTransition = { event, _, attrs in
            events.append(CapturedTransition(event: event, attrs: attrs))
        }

        for count in 1...3 {
            try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: count)
        }

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.event, .mergabilityChanged)
        XCTAssertEqual(events.first?.attrs["from"], PRInfo.Mergeable.mergeable.rawValue)
        XCTAssertEqual(events.first?.attrs["to"], PRInfo.Mergeable.conflicting.rawValue)
    }

    func testRepeatedMergeabilityAbsenceAndRecoveryEmitsOneRealChange() async throws {
        let harness = makeStore(snapshots: [
            snapshot(info(checks: .success, mergeable: .mergeable)),
            snapshot(info(checks: .success, mergeable: .unknown)),
            snapshot(info(checks: .success, mergeable: .conflicting)),
            snapshot(info(checks: .success, mergeable: .unknown)),
            snapshot(info(checks: .success, mergeable: .conflicting)),
        ])
        defer { harness.store.stop() }
        var events: [CapturedTransition] = []
        harness.store.onTransition = { event, _, attrs in
            events.append(CapturedTransition(event: event, attrs: attrs))
        }

        for count in 1...5 {
            try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: count)
        }

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.event, .mergabilityChanged)
        XCTAssertEqual(events.first?.attrs["from"], PRInfo.Mergeable.mergeable.rawValue)
        XCTAssertEqual(events.first?.attrs["to"], PRInfo.Mergeable.conflicting.rawValue)
    }

    func testChecksAbsenceAndRecoveryUsesLastMeaningfulConclusion() async throws {
        let harness = makeStore(snapshots: [
            snapshot(info(checks: .success, mergeable: .mergeable)),
            snapshot(info(checks: .none, mergeable: .mergeable)),
            snapshot(info(checks: .failure, mergeable: .mergeable)),
            snapshot(info(checks: .none, mergeable: .mergeable)),
            snapshot(info(checks: .failure, mergeable: .mergeable)),
        ])
        defer { harness.store.stop() }
        var events: [CapturedTransition] = []
        harness.store.onTransition = { event, _, attrs in
            events.append(CapturedTransition(event: event, attrs: attrs))
        }

        try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: 1)
        try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: 2)
        XCTAssertEqual(harness.store.infos[Self.worktreePath]?.checks, PRInfo.Checks.none)
        for count in 3...5 {
            try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: count)
        }

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.event, .ciConclusionChanged)
        XCTAssertEqual(events.first?.attrs["from"], PRInfo.Checks.success.rawValue)
        XCTAssertEqual(events.first?.attrs["to"], PRInfo.Checks.failure.rawValue)
    }

    func testInitialAbsenceThenMeaningfulVerdictSeedsWithoutFiring() async throws {
        let harness = makeStore(snapshots: [
            snapshot(info(checks: .none, mergeable: .unknown)),
            snapshot(info(checks: .success, mergeable: .mergeable)),
        ])
        defer { harness.store.stop() }
        var events: [CapturedTransition] = []
        harness.store.onTransition = { event, _, attrs in
            events.append(CapturedTransition(event: event, attrs: attrs))
        }

        for count in 1...2 {
            try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: count)
        }

        XCTAssertTrue(events.isEmpty)
    }

    func testPRDisappearanceResetsMeaningfulBaselines() async throws {
        let harness = makeStore(snapshots: [
            snapshot(info(checks: .success, mergeable: .mergeable)),
            snapshot(nil),
            snapshot(info(checks: .failure, mergeable: .conflicting)),
        ])
        defer { harness.store.stop() }
        var events: [CapturedTransition] = []
        harness.store.onTransition = { event, _, attrs in
            events.append(CapturedTransition(event: event, attrs: attrs))
        }

        for count in 1...3 {
            try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: count)
        }

        XCTAssertTrue(events.isEmpty)
    }

    func testClearResetsMeaningfulBaselines() async throws {
        let harness = makeStore(snapshots: [
            snapshot(info(checks: .success, mergeable: .mergeable)),
            snapshot(info(checks: .failure, mergeable: .conflicting)),
        ])
        defer { harness.store.stop() }
        var events: [CapturedTransition] = []
        harness.store.onTransition = { event, _, attrs in
            events.append(CapturedTransition(event: event, attrs: attrs))
        }

        try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: 1)
        harness.store.clear(worktreePath: Self.worktreePath)
        try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: 2)

        XCTAssertTrue(events.isEmpty)
    }

    func testPRIdentityChangeSeedsBeforeLaterTransitions() async throws {
        let harness = makeStore(snapshots: [
            snapshot(info(number: 5, checks: .success, mergeable: .mergeable)),
            snapshot(info(number: 6, checks: .failure, mergeable: .conflicting)),
            snapshot(info(number: 6, checks: .success, mergeable: .mergeable)),
        ])
        defer { harness.store.stop() }
        var events: [CapturedTransition] = []
        harness.store.onTransition = { event, _, attrs in
            events.append(CapturedTransition(event: event, attrs: attrs))
        }

        try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: 1)
        try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: 2)
        XCTAssertTrue(events.isEmpty, "different PR identities must not be compared")
        XCTAssertEqual(harness.store.infos[Self.worktreePath]?.number, 6)

        try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: 3)
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.contains { $0.event == .ciConclusionChanged })
        XCTAssertTrue(events.contains { $0.event == .mergabilityChanged })
        XCTAssertTrue(events.allSatisfy { $0.attrs["pr_number"] == "6" })
    }

    func testCanonicalURLChangeDoesNotChangePRIdentity() async throws {
        let oldURL = URL(string: "https://github.com/acme/web/pull/5")!
        let canonicalURL = URL(string: "https://github.com/acme/renamed-web/pull/5")!
        let harness = makeStore(snapshots: [
            snapshot(info(
                url: oldURL,
                checks: .success,
                mergeable: .mergeable
            )),
            snapshot(info(
                url: canonicalURL,
                checks: .failure,
                mergeable: .conflicting
            )),
        ])
        defer { harness.store.stop() }
        var events: [CapturedTransition] = []
        harness.store.onTransition = { event, _, attrs in
            events.append(CapturedTransition(event: event, attrs: attrs))
        }

        try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: 1)
        try await refresh(harness.store, fetcher: harness.fetcher, expectedFetchCount: 2)

        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.contains { $0.event == .ciConclusionChanged })
        XCTAssertTrue(events.contains { $0.event == .mergabilityChanged })
        XCTAssertTrue(events.allSatisfy { $0.attrs["pr_url"] == canonicalURL.absoluteString })
    }
}

private actor SequencedPRFetcher: PRFetcher {
    private var snapshots: [RepoPRSnapshot]
    private var completedFetches = 0

    init(snapshots: [RepoPRSnapshot]) {
        self.snapshots = snapshots
    }

    var fetchCount: Int {
        completedFetches
    }

    func fetch(
        origin: HostingOrigin,
        branchesOfInterest: Set<String>
    ) async throws -> RepoPRSnapshot {
        guard !snapshots.isEmpty else {
            throw SequencedPRFetcherError.exhausted
        }
        completedFetches += 1
        return snapshots.removeFirst()
    }
}

private enum SequencedPRFetcherError: Error {
    case exhausted
}
