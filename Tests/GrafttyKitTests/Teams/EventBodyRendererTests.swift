import Foundation
import Testing
@testable import GrafttyKit

@Suite("EventBodyRenderer.split — split + auto-append + body variable")
struct EventBodyRendererSplitTests {
    @Test("Empty template: passthrough — agentPrompt nil, event body unchanged.")
    func emptyTemplatePassthrough() {
        let event = ChannelServerMessage.event(
            type: "pr_state_changed",
            attrs: [:],
            body: "PR #1 went open → ready"
        )
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [Self.fixtureRepo()],
            templateString: ""
        )
        #expect(result.agentPrompt == nil)
        #expect(Self.body(result.event) == "PR #1 went open → ready")
    }

    @Test("Template without {{ body }} → auto-append: agentPrompt contains both prelude and body.")
    func autoAppendsBodyWhenTemplateLacksReference() throws {
        let event = ChannelServerMessage.event(type: "pr_state_changed", attrs: [:], body: "EVENT-CONTENT")
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [Self.fixtureRepo()],
            templateString: "Hello {{ agent.branch }}."
        )
        let prompt = try #require(result.agentPrompt)
        #expect(prompt.contains("Hello alice."))
        #expect(prompt.contains("EVENT-CONTENT"))
        #expect(Self.body(result.event) == "EVENT-CONTENT")
    }

    @Test("Template with explicit {{ body }} → no auto-append: author placement honored.")
    func respectsExplicitBodyReference() {
        let event = ChannelServerMessage.event(type: "pr_state_changed", attrs: [:], body: "EVENT-CONTENT")
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [Self.fixtureRepo()],
            templateString: "Before: {{ body }} :After"
        )
        #expect(result.agentPrompt == "Before: EVENT-CONTENT :After")
    }

    @Test("Template with {{body}} (no internal whitespace) → no auto-append (regex tolerates whitespace variants).")
    func toleratesNoSpaceBodyReference() {
        let event = ChannelServerMessage.event(type: "pr_state_changed", attrs: [:], body: "X")
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [Self.fixtureRepo()],
            templateString: "[{{body}}]"
        )
        #expect(result.agentPrompt == "[X]")
    }

    @Test("Template that suppresses body via false-branch {% if %} renders without the body.")
    func suppressedBodyProducesPromptWithoutBody() {
        let event = ChannelServerMessage.event(type: "pr_state_changed", attrs: [:], body: "DO-NOT-SHOW")
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [Self.fixtureRepo()],
            templateString: "Suppressed{% if false %}{{ body }}{% endif %}"
        )
        #expect(result.agentPrompt == "Suppressed")
        #expect(Self.body(result.event) == "DO-NOT-SHOW")
    }

    @Test("Malformed Stencil → passthrough.")
    func renderFailurePassthrough() {
        let event = ChannelServerMessage.event(type: "pr_state_changed", attrs: [:], body: "EVENT")
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [Self.fixtureRepo()],
            templateString: "{% if %}"
        )
        #expect(result.agentPrompt == nil)
        #expect(Self.body(result.event) == "EVENT")
    }

    private static func fixtureRepo() -> RepoEntry {
        // The repo's main worktree is the lead; alice is a coworker.
        // One repo with two worktrees: "main" at /r and "alice" at
        // /r/alice with branch "alice".
        RepoEntry(
            path: "/r",
            displayName: "r",
            worktrees: [
                WorktreeEntry(path: "/r", branch: "main", state: .running),
                WorktreeEntry(path: "/r/alice", branch: "alice", state: .running),
            ]
        )
    }

    private static func body(_ event: ChannelServerMessage) -> String {
        guard case let .event(_, _, body) = event else { return "" }
        return body
    }
}
