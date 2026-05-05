import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("TeamActivityLogViewModel.renderedItems — continuation + day dividers")
struct TeamActivityLogViewModelRenderedItemsTests {
    @Test("Two chat messages from the same worktree within 5 minutes: second is a continuation.")
    func continuationWithinWindow() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let messages = [
            chatMessage(id: "m1", from: "alice", body: "first", at: now),
            chatMessage(id: "m2", from: "alice", body: "second", at: now.addingTimeInterval(60)),
        ]
        let items = TeamActivityLogViewModel.renderedItems(from: messages, calendar: .current)
        #expect(items.count == 2)
        #expect(items[0].isContinuation == false)
        #expect(items[1].isContinuation == true)
    }

    @Test("Two chat messages from the same worktree more than 5 minutes apart: not a continuation.")
    func continuationBeyondWindow() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let messages = [
            chatMessage(id: "m1", from: "alice", body: "first", at: now),
            chatMessage(id: "m2", from: "alice", body: "second", at: now.addingTimeInterval(360)),
        ]
        let items = TeamActivityLogViewModel.renderedItems(from: messages, calendar: .current)
        #expect(items[1].isContinuation == false)
    }

    @Test("A message from a different worktree breaks the continuation chain.")
    func differentWorktreeBreaksContinuation() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let messages = [
            chatMessage(id: "m1", from: "alice", body: "a", at: now),
            chatMessage(id: "m2", from: "bob", body: "b", at: now.addingTimeInterval(60)),
            chatMessage(id: "m3", from: "alice", body: "c", at: now.addingTimeInterval(90)),
        ]
        let items = TeamActivityLogViewModel.renderedItems(from: messages, calendar: .current)
        #expect(items[1].isContinuation == false)
        #expect(items[2].isContinuation == false)
    }

    @Test("A memberJoined marker between two same-worktree messages breaks the chain.")
    func markerBreaksContinuation() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let messages = [
            chatMessage(id: "m1", from: "alice", body: "a", at: now),
            joinedMessage(id: "m2", member: "carol", at: now.addingTimeInterval(30)),
            chatMessage(id: "m3", from: "alice", body: "c", at: now.addingTimeInterval(60)),
        ]
        let items = TeamActivityLogViewModel.renderedItems(from: messages, calendar: .current)
        // Continuation flag is only meaningful on chat/system rows.
        #expect(items[2].isContinuation == false)
    }

    @Test("Two messages straddling local midnight insert a day divider between them.")
    func dayDividerInsertedAtMidnight() {
        let cal = Calendar(identifier: .gregorian)
        // 2026-03-04 23:59:30 local
        let evening = DateComponents(
            calendar: cal, year: 2026, month: 3, day: 4, hour: 23, minute: 59, second: 30
        ).date!
        // 2026-03-05 00:00:30 local
        let morning = DateComponents(
            calendar: cal, year: 2026, month: 3, day: 5, hour: 0, minute: 0, second: 30
        ).date!
        let messages = [
            chatMessage(id: "m1", from: "alice", body: "a", at: evening),
            chatMessage(id: "m2", from: "alice", body: "b", at: morning),
        ]
        let items = TeamActivityLogViewModel.renderedItems(from: messages, calendar: cal)
        #expect(items.count == 3)
        guard case .dayDivider = items[1].row else {
            Issue.record("expected day-divider variant at index 1, got \(items[1].row)")
            return
        }
        // Day-divider breaks continuation too.
        #expect(items[2].isContinuation == false)
    }

    @Test("System events get continuation collapsing on the same scope-worktree.")
    func systemContinuationByScopedWorktree() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let messages = [
            systemMessage(id: "m1", scope: "codex-hooks", kind: "pr_state_changed",
                          body: "open → ready", at: now),
            systemMessage(id: "m2", scope: "codex-hooks", kind: "ci_conclusion_changed",
                          body: "pending → success", at: now.addingTimeInterval(45)),
        ]
        let items = TeamActivityLogViewModel.renderedItems(from: messages, calendar: .current)
        #expect(items[1].isContinuation == true)
    }

    // MARK: - Fixtures

    private func chatMessage(id: String, from: String, body: String, at: Date) -> TeamInboxMessage {
        TeamInboxMessage(
            id: id, batchID: nil, createdAt: at, team: "team", repoPath: "/repo",
            from: TeamInboxEndpoint(member: from, worktree: "/repo/\(from)", runtime: nil),
            to: TeamInboxEndpoint(member: from, worktree: "/repo/\(from)", runtime: nil),
            priority: .normal, kind: "team_message", body: body
        )
    }

    private func systemMessage(
        id: String, scope: String, kind: String, body: String, at: Date
    ) -> TeamInboxMessage {
        TeamInboxMessage(
            id: id, batchID: nil, createdAt: at, team: "team", repoPath: "/repo",
            from: .system(repoPath: "/repo"),
            to: TeamInboxEndpoint(member: scope, worktree: "/repo/\(scope)", runtime: nil),
            priority: .normal, kind: kind, body: body
        )
    }

    private func joinedMessage(id: String, member: String, at: Date) -> TeamInboxMessage {
        TeamInboxMessage(
            id: id, batchID: nil, createdAt: at, team: "team", repoPath: "/repo",
            from: .system(repoPath: "/repo"),
            to: TeamInboxEndpoint(member: member, worktree: "/repo/\(member)", runtime: nil),
            priority: .normal, kind: "team_member_joined", body: ""
        )
    }
}
