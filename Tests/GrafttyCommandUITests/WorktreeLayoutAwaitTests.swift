import GrafttyProtocol
import Testing
@testable import GrafttyCommandUI

@MainActor
@Suite("WorktreeLayoutAwait")
struct WorktreeLayoutAwaitTests {
    private func row(_ state: WorktreeWireState) -> WorktreePanes {
        .init(path: "/wt", displayName: "wt", repoDisplayName: "Repo", displayBranch: "main", state: state,
            isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: state == .running ? .leaf(sessionName: "pane", title: "", attentionText: nil, isBusy: false, attentionSource: nil) : nil)
    }

    private func running(_ rows: [WorktreePanes]) -> WorktreePanes? {
        rows.first { $0.state == .running }
    }

    @Test func readyInitialSnapshotNeedsNoFetchOrPause() async throws {
        var fetches = 0, pauses = 0
        let result = try await WorktreeLayoutAwait.poll(rows: [row(.running)], fetch: {
            fetches += 1; return []
        }, checkCurrent: {}, pause: { pauses += 1 }, ready: running)
        #expect(result == row(.running))
        #expect(fetches == 0 && pauses == 0)
    }

    @Test func checksTwelveSnapshotsThenGivesUpWithoutTrailingPause() async throws {
        var fetches = 0, pauses = 0, checks = 0
        let result = try await WorktreeLayoutAwait.poll(rows: [row(.closed)], fetch: {
            fetches += 1; return [row(.closed)]
        }, checkCurrent: {}, pause: { pauses += 1 }, ready: { rows in
            checks += 1; return running(rows)
        })
        #expect(result == nil)
        #expect(checks == 12)
        #expect(fetches == 11)
        #expect(pauses == 11)
    }

    @Test func layoutArrivingInALaterSnapshotIsReturned() async throws {
        var fetches = 0
        let result = try await WorktreeLayoutAwait.poll(rows: [row(.closed)], fetch: {
            fetches += 1; return [row(fetches < 3 ? .closed : .running)]
        }, checkCurrent: {}, pause: {}, ready: running)
        #expect(result == row(.running))
        #expect(fetches == 3)
    }

    @Test func supersededRequestStopsBeforeTheNextFetch() async throws {
        var current = true, fetches = 0
        await #expect(throws: CancellationError.self) {
            _ = try await WorktreeLayoutAwait.poll(rows: [row(.closed)], fetch: {
                fetches += 1; return [row(.closed)]
            }, checkCurrent: {
                guard current else { throw CancellationError() }
            }, pause: { current = false }, ready: running)
        }
        #expect(fetches == 0)
    }

    @Test func readyCanEndThePollWithItsOwnError() async throws {
        struct Gone: Error {}
        await #expect(throws: Gone.self) {
            _ = try await WorktreeLayoutAwait.poll(rows: [], fetch: { [] }, checkCurrent: {}, pause: {},
                ready: { (_: [WorktreePanes]) -> WorktreePanes? in throw Gone() })
        }
    }
}
