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

    @Test("Auto-append trims trailing whitespace from the template so a template ending in \\n doesn't produce three blank lines before the body.")
    func autoAppendTrimsTemplateTrailingWhitespace() throws {
        let event = ChannelServerMessage.event(type: "pr_state_changed", attrs: [:], body: "EVENT-CONTENT")
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [Self.fixtureRepo()],
            templateString: "Hello.\n"
        )
        let prompt = try #require(result.agentPrompt)
        #expect(prompt == "Hello.\n\nEVENT-CONTENT")
    }

    private static func fixtureRepo() -> RepoEntry { eventBodyRendererFixtureRepo() }

    private static func body(_ event: ChannelServerMessage) -> String {
        guard case let .event(_, _, body) = event else { return "" }
        return body
    }
}

/// Shared two-worktree fixture: lead `main` at `/r`, coworker `alice` at `/r/alice`.
fileprivate func eventBodyRendererFixtureRepo() -> RepoEntry {
    RepoEntry(
        path: "/r",
        displayName: "r",
        worktrees: [
            WorktreeEntry(path: "/r",       branch: "main",  state: .running),
            WorktreeEntry(path: "/r/alice", branch: "alice", state: .running),
        ]
    )
}

@Suite("""
@spec TEAM-1.11: When `EventBodyRenderer.split` renders the per-event `teamPrompt` template, the application shall expose a top-level `event` object on the render context with `event.type` (wire-format event-type string), `event.attrs` (the event's attribute dictionary), and `event.body` (the original event body) — letting templates branch on the event type via a chained `{% if event.type == "…" %} … {% elif … %}` block (Stencil has no `case`/`switch` tag).
""")
struct EventBodyRendererEventContextTests {

    @Test("`{{ event.type }}` resolves to the wire-format event-type string.")
    func exposesEventTypeVariable() throws {
        let result = renderWithTemplate("type={{ event.type }}", eventType: "merge_state_changed")
        let prompt = try #require(result.agentPrompt)
        #expect(prompt.hasPrefix("type=merge_state_changed"))
    }

    @Test("Templates can branch on event.type via chained {% if … elif %}.")
    func branchesOnEventTypeViaChainedIf() throws {
        let result = renderWithTemplate(
            """
            {% if event.type == "merge_state_changed" -%}
            MERGE
            {%- elif event.type == "pr_state_changed" -%}
            PR
            {%- endif %}
            """,
            eventType: "merge_state_changed"
        )
        let prompt = try #require(result.agentPrompt)
        #expect(prompt.hasPrefix("MERGE"))
    }

    @Test("`{{ event.attrs.<key> }}` resolves attributes from the event payload.")
    func exposesEventAttrs() throws {
        let result = renderWithTemplate(
            "pr={{ event.attrs.pr_number }}",
            eventType: "pr_state_changed",
            attrs: ["pr_number": "42"]
        )
        let prompt = try #require(result.agentPrompt)
        #expect(prompt.hasPrefix("pr=42"))
    }

    private func renderWithTemplate(
        _ template: String,
        eventType: String,
        attrs: [String: String] = [:]
    ) -> EventBodyRendererResult {
        EventBodyRenderer.split(
            event: .event(type: eventType, attrs: attrs, body: "BODY"),
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [eventBodyRendererFixtureRepo()],
            templateString: template
        )
    }
}
