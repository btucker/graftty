import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("ActivityFeedRow.resolve — message → variant mapping")
struct ActivityFeedRowResolveTests {
    @Test("team_message from a non-system sender becomes a chat variant.")
    func teamMessageBecomesChat() {
        let msg = Self.message(
            kind: "team_message",
            from: .member("alice"),
            to: .member("bob"),
            body: "ping"
        )
        #expect(ActivityFeedRow.resolve(msg) == .chat(
            worktree: "alice",
            recipient: "bob",
            body: "ping",
            timestamp: msg.createdAt,
            isUrgent: false
        ))
    }

    @Test("team_message with priority urgent surfaces isUrgent=true.")
    func urgentChatFlag() {
        let msg = Self.message(
            kind: "team_message",
            from: .member("alice"),
            to: .member("bob"),
            priority: .urgent,
            body: "hold"
        )
        guard case let .chat(_, _, _, _, isUrgent) = ActivityFeedRow.resolve(msg) else {
            Issue.record("expected chat variant")
            return
        }
        #expect(isUrgent == true)
    }

    @Test("team_message where from == to drops the recipient suffix.")
    func selfMessageHasNoRecipient() {
        let msg = Self.message(
            kind: "team_message",
            from: .member("alice"),
            to: .member("alice"),
            body: "note"
        )
        guard case let .chat(_, recipient, _, _, _) = ActivityFeedRow.resolve(msg) else {
            Issue.record("expected chat variant")
            return
        }
        #expect(recipient == nil)
    }

    @Test("team_member_joined becomes a memberJoined centered marker.")
    func memberJoined() {
        let msg = Self.message(
            kind: "team_member_joined",
            from: .system,
            to: .member("alice"),
            body: ""
        )
        #expect(ActivityFeedRow.resolve(msg) == .memberJoined(worktree: "alice"))
    }

    @Test("team_member_left becomes a memberLeft centered marker.")
    func memberLeft() {
        let msg = Self.message(
            kind: "team_member_left",
            from: .system,
            to: .member("alice"),
            body: ""
        )
        #expect(ActivityFeedRow.resolve(msg) == .memberLeft(worktree: "alice"))
    }

    @Test("pr_state_changed becomes a system row scoped to to.member with the PR icon.")
    func prStateChanged() {
        let msg = Self.message(
            kind: "pr_state_changed",
            from: .system,
            to: .member("codex-hooks"),
            body: "PR #1234 went open → ready_for_review"
        )
        #expect(ActivityFeedRow.resolve(msg) == .system(
            worktree: "codex-hooks",
            iconName: "circle.fill",
            body: "PR #1234 went open → ready_for_review",
            timestamp: msg.createdAt
        ))
    }

    @Test("ci_conclusion_changed uses the CI icon.")
    func ciConclusionChanged() {
        let msg = Self.message(
            kind: "ci_conclusion_changed",
            from: .system,
            to: .member("codex-hooks"),
            body: "CI went pending → success"
        )
        guard case let .system(_, iconName, _, _) = ActivityFeedRow.resolve(msg) else {
            Issue.record("expected system variant")
            return
        }
        #expect(iconName == "checkmark.seal")
    }

    @Test("merge_state_changed uses the merge icon.")
    func mergeStateChanged() {
        let msg = Self.message(
            kind: "merge_state_changed",
            from: .system,
            to: .member("codex-hooks"),
            body: "Mergeability went unknown → clean"
        )
        guard case let .system(_, iconName, _, _) = ActivityFeedRow.resolve(msg) else {
            Issue.record("expected system variant")
            return
        }
        #expect(iconName == "arrow.triangle.merge")
    }

    @Test("Unknown kind falls back to a system row with the info-circle icon.")
    func unknownKindFallback() {
        let msg = Self.message(
            kind: "future_event_kind",
            from: .system,
            to: .member("codex-hooks"),
            body: "something happened"
        )
        guard case let .system(worktree, iconName, body, _) = ActivityFeedRow.resolve(msg) else {
            Issue.record("expected system variant")
            return
        }
        #expect(worktree == "codex-hooks")
        #expect(iconName == "info.circle")
        #expect(body == "something happened")
    }

    // MARK: - Fixtures

    private enum Endpoint {
        case member(String)
        case system
    }

    private static func message(
        kind: String,
        from: Endpoint,
        to: Endpoint,
        priority: TeamInboxPriority = .normal,
        body: String,
        createdAt: Date = Date()
    ) -> TeamInboxMessage {
        TeamInboxMessage(
            id: UUID().uuidString,
            batchID: nil,
            createdAt: createdAt,
            team: "team",
            repoPath: "/repo",
            from: endpoint(from),
            to: endpoint(to),
            priority: priority,
            kind: kind,
            body: body
        )
    }

    private static func endpoint(_ e: Endpoint) -> TeamInboxEndpoint {
        switch e {
        case .member(let name):
            return TeamInboxEndpoint(member: name, worktree: "/repo/\(name)", runtime: nil)
        case .system:
            return .system(repoPath: "/repo")
        }
    }
}
