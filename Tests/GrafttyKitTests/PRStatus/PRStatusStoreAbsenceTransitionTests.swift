import XCTest
import GrafttyProtocol
@testable import GrafttyKit

/// @spec PR-8.24: The `checks == .none` and `mergeable == .unknown`
/// values denote *absence of a signal* (an empty / all-neutral
/// `statusCheckRollup`, or GitHub's transient "still recomputing"
/// mergeability), not a settled conclusion. When a CI-conclusion or
/// mergeability transition's destination is one of those absence
/// values, the application shall NOT fire a change notification — a
/// blip toward "no signal" is not something an agent should be woken
/// for. Transitions INTO a real value (`.success` / `.failure`,
/// `.mergeable` / `.conflicting`) still fire.
@MainActor
final class PRStatusStoreAbsenceTransitionTests: XCTestCase {
    private static let origin = HostingOrigin(
        provider: .github, host: "github.com", owner: "acme", repo: "web"
    )
    private static let url = URL(string: "https://github.com/acme/web/pull/5")!

    private func info(
        checks: PRInfo.Checks,
        mergeable: PRInfo.Mergeable = .unknown,
        state: PRInfo.State = .open
    ) -> PRInfo {
        PRInfo(number: 5, title: "t", url: Self.url, state: state,
               checks: checks, mergeable: mergeable, fetchedAt: Date())
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

    /// The suppression is destination-scoped: a transition INTO a real
    /// value still fires, so genuine outcomes are never swallowed.
    func testTransitionsIntoRealValuesStillFire() {
        let store = PRStatusStore()
        var events: [RoutableEvent] = []
        store.onTransition = { event, _, _ in events.append(event) }

        // none → success (the real "CI passed" edge after a transient none).
        store.detectAndFireTransitionsForTesting(
            worktreePath: "/wt/a",
            previous: info(checks: .none, mergeable: .mergeable),
            current: info(checks: .success, mergeable: .mergeable),
            origin: Self.origin
        )
        XCTAssertEqual(events, [.ciConclusionChanged])

        // unknown → conflicting (the real mergeability edge).
        events.removeAll()
        store.detectAndFireTransitionsForTesting(
            worktreePath: "/wt/a",
            previous: info(checks: .success, mergeable: .unknown),
            current: info(checks: .success, mergeable: .conflicting),
            origin: Self.origin
        )
        XCTAssertEqual(events, [.mergabilityChanged])
    }
}
