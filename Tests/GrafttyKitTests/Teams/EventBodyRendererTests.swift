import Testing
import Foundation
@testable import GrafttyKit

@Suite("EventBodyRenderer")
struct EventBodyRendererTests {

    private func makeRepo() -> RepoEntry {
        TeamTestFixtures.makeRepo(branches: ["main", "feature/login"])
    }

    private func makeEvent(_ body: String = "PR #42 merged.") -> ChannelServerMessage {
        .event(type: "pr_state_changed", attrs: ["to": "merged"], body: body)
    }

    @Test func emptyTemplatePassesThrough() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: ""
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event variant"); return
        }
        #expect(body == "PR #42 merged.")
    }

    @Test func happyPathPrependsRendered() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: "Lead got an event."
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body == "Lead got an event.\n\nPR #42 merged.")
    }

    @Test func leadFlagIsTrueForRootRecipient() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: "{% if agent.lead %}LEAD{% else %}NOT_LEAD{% endif %}"
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body.hasPrefix("LEAD"))
    }

    @Test func leadFlagIsFalseForCoworker() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi/.worktrees/feature-login",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: "{% if agent.lead %}LEAD{% else %}NOT_LEAD{% endif %}"
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body.hasPrefix("NOT_LEAD"))
    }

    @Test func thisWorktreeFlagIsTrueWhenRecipientIsSubject() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi/.worktrees/feature-login",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: "{% if agent.this_worktree %}MINE{% else %}NOT_MINE{% endif %}"
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body.hasPrefix("MINE"))
    }

    @Test func otherWorktreeFlagIsTrueWhenRecipientIsNotSubject() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: "{% if agent.other_worktree %}OTHER{% else %}NOT_OTHER{% endif %}"
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body.hasPrefix("OTHER"))
    }

    @Test func nilSubjectMakesBothPerEventFlagsFalse() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: .event(type: "team_message", attrs: ["from": "lead"], body: "hi"),
            recipientWorktreePath: "/r/multi/.worktrees/feature-login",
            subjectWorktreePath: nil,
            repos: [repo],
            templateString: "{% if agent.this_worktree %}T{% endif %}{% if agent.other_worktree %}O{% endif %}NEITHER"
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body.hasPrefix("NEITHER"))
    }

    @Test func renderFailureFallsBackToOriginal() {
        let repo = makeRepo()
        // Unbalanced tags — Stencil throws.
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: "{% if agent.lead %}unclosed"
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body == "PR #42 merged.")
    }

    @Test func whitespaceOnlyRenderSkipsPrepend() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: "{% if agent.lead %}  {% endif %}"
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body == "PR #42 merged.")
    }
}
