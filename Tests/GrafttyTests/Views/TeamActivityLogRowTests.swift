import XCTest
import SwiftUI
@testable import Graftty
@testable import GrafttyKit

final class TeamActivityLogRowTests: XCTestCase {
    /// @spec TEAM-7.5: When the inbox row is rendered in the activity
    /// log, the application shall render `team_message` rows from a
    /// non-system sender as a chat bubble (sender → recipient,
    /// timestamp, urgent badge if `priority == .urgent`) and every
    /// other row (system sender, or a non-`team_message` kind) as a
    /// system entry with a kind-specific SF Symbol and headline.
    func testChatBubbleVsSystemEntry() {
        let bubble = TeamActivityLogRow(message: TeamInboxMessage(
            id: "1", batchID: nil, createdAt: Date(), team: "t", repoPath: "/r",
            from: TeamInboxEndpoint(member: "alice", worktree: "/r/a", runtime: nil),
            to: TeamInboxEndpoint(member: "bob", worktree: "/r/b", runtime: nil),
            priority: .normal, kind: "team_message", body: "ping"
        ))
        XCTAssertEqual(
            bubble.style,
            .chatBubble(senderName: "alice", recipientName: "bob", priority: .normal)
        )

        let prRow = TeamActivityLogRow(message: TeamInboxMessage(
            id: "2", batchID: nil, createdAt: Date(), team: "t", repoPath: "/r",
            from: .system(repoPath: "/r"),
            to: TeamInboxEndpoint(member: "alice", worktree: "/r/a", runtime: nil),
            priority: .normal, kind: "pr_state_changed",
            body: "PR #42 state changed: open → merged"
        ))
        XCTAssertEqual(
            prRow.style,
            .systemEntry(symbolName: "circle.fill", headline: "PR state changed")
        )

        let ciRow = TeamActivityLogRow(message: TeamInboxMessage(
            id: "3", batchID: nil, createdAt: Date(), team: "t", repoPath: "/r",
            from: .system(repoPath: "/r"),
            to: TeamInboxEndpoint(member: "alice", worktree: "/r/a", runtime: nil),
            priority: .normal, kind: "ci_conclusion_changed", body: "CI passed"
        ))
        XCTAssertEqual(
            ciRow.style,
            .systemEntry(symbolName: "checkmark.seal", headline: "CI conclusion changed")
        )

        let mergeRow = TeamActivityLogRow(message: TeamInboxMessage(
            id: "4", batchID: nil, createdAt: Date(), team: "t", repoPath: "/r",
            from: .system(repoPath: "/r"),
            to: TeamInboxEndpoint(member: "alice", worktree: "/r/a", runtime: nil),
            priority: .normal, kind: "merge_state_changed",
            body: "merge state: clean → dirty"
        ))
        XCTAssertEqual(
            mergeRow.style,
            .systemEntry(symbolName: "arrow.triangle.merge", headline: "Mergability changed")
        )

        let joinedRow = TeamActivityLogRow(message: TeamInboxMessage(
            id: "5", batchID: nil, createdAt: Date(), team: "t", repoPath: "/r",
            from: .system(repoPath: "/r"),
            to: TeamInboxEndpoint(member: "lead", worktree: "/r", runtime: nil),
            priority: .normal, kind: "team_member_joined",
            body: "Coworker joined"
        ))
        XCTAssertEqual(
            joinedRow.style,
            .systemEntry(symbolName: "person.fill.badge.plus", headline: "Team member joined")
        )

        let leftRow = TeamActivityLogRow(message: TeamInboxMessage(
            id: "6", batchID: nil, createdAt: Date(), team: "t", repoPath: "/r",
            from: .system(repoPath: "/r"),
            to: TeamInboxEndpoint(member: "lead", worktree: "/r", runtime: nil),
            priority: .normal, kind: "team_member_left",
            body: "Coworker left"
        ))
        XCTAssertEqual(
            leftRow.style,
            .systemEntry(symbolName: "person.fill.badge.minus", headline: "Team member left")
        )

        let urgentBubble = TeamActivityLogRow(message: TeamInboxMessage(
            id: "7", batchID: nil, createdAt: Date(), team: "t", repoPath: "/r",
            from: TeamInboxEndpoint(member: "alice", worktree: "/r/a", runtime: nil),
            to: TeamInboxEndpoint(member: "bob", worktree: "/r/b", runtime: nil),
            priority: .urgent, kind: "team_message", body: "WAKE UP"
        ))
        XCTAssertEqual(
            urgentBubble.style,
            .chatBubble(senderName: "alice", recipientName: "bob", priority: .urgent)
        )
    }

    /// @spec TEAM-7.7: When the inbox row's `kind` is not one of the
    /// known team-event kinds, the application shall render it as a
    /// generic system entry with the `info.circle` SF Symbol and the
    /// raw `kind` string as the headline so a forward-compatible client
    /// still surfaces unknown rows readably.
    func testRendersGenericSystemEntryForUnknownKind() {
        let msg = TeamInboxMessage(
            id: "u1", batchID: nil, createdAt: Date(), team: "t", repoPath: "/r",
            from: .system(repoPath: "/r"),
            to: TeamInboxEndpoint(member: "alice", worktree: "/r/a", runtime: nil),
            priority: .normal, kind: "future_kind", body: "hello"
        )
        let row = TeamActivityLogRow(message: msg)
        XCTAssertEqual(
            row.style,
            .systemEntry(symbolName: "info.circle", headline: "future_kind")
        )
    }
}
