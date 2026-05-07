import Testing
import SwiftUI
import GrafttyKit
@testable import Graftty

@Suite("AgentTeamsSettingsPane Tests")
struct AgentTeamsSettingsPaneTests {

    @Test func defaultPromptsAreNonEmpty() {
        #expect(!DefaultPrompts.sessionPrompt.isEmpty)
        #expect(!DefaultPrompts.eventPrompt.isEmpty)
    }

    /// Session prompt runs at session start, before any event has arrived,
    /// so the event-scoped fields are always `false`. The default template
    /// must not lean on them — and the UI's variable list intentionally
    /// hides them.
    @Test func sessionPromptOmitsEventScopedVariables() {
        #expect(DefaultPrompts.sessionPrompt.contains("agent.branch"))
        #expect(DefaultPrompts.sessionPrompt.contains("agent.lead"))
        #expect(!DefaultPrompts.sessionPrompt.contains("agent.this_worktree"))
        #expect(!DefaultPrompts.sessionPrompt.contains("agent.other_worktree"))
    }

    /// Per-event prompt runs per delivery and should react to whether the
    /// event concerns the agent's own worktree.
    @Test func eventPromptUsesEventScopedVariables() {
        let p = DefaultPrompts.eventPrompt
        #expect(p.contains("agent.this_worktree") || p.contains("agent.other_worktree"))
    }

    /// Catches Stencil syntax errors in the defaults across the four agent
    /// shapes a real delivery could produce: lead vs coworker × event-about-
    /// self vs event-about-peer vs no-event-yet.
    @Test func defaultPromptsRenderUnderEveryAgentContext() {
        let shapes: [(lead: Bool, thisWorktree: Bool, otherWorktree: Bool)] = [
            (true,  false, false),
            (false, true,  false),
            (false, false, true ),
            (false, false, false),
        ]
        for s in shapes {
            let ctx = EventBodyRenderer.makeAgentContext(
                branch: "b",
                lead: s.lead,
                thisWorktree: s.thisWorktree,
                otherWorktree: s.otherWorktree
            )
            #expect(EventBodyRenderer.renderAgentTemplate(DefaultPrompts.sessionPrompt, agent: ctx) != nil)
            #expect(EventBodyRenderer.renderAgentTemplate(DefaultPrompts.eventPrompt,   agent: ctx) != nil)
        }
    }

    /// The default per-event template uses a chained `{% if event.type == "…" %}`
    /// (Stencil has no `case`/`switch` tag) to give event-specific guidance.
    /// The merge_state_changed branch tells the agent to merge the default branch.
    @Test func defaultEventPromptBranchesOnEventType() throws {
        let event = ChannelServerMessage.event(
            type: "merge_state_changed",
            attrs: ["pr_number": "42", "from": "clean", "to": "dirty"],
            body: "PR #42 mergability: clean → dirty"
        )
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [
                RepoEntry(
                    path: "/r",
                    displayName: "r",
                    worktrees: [
                        WorktreeEntry(path: "/r",       branch: "main",  state: .running),
                        WorktreeEntry(path: "/r/alice", branch: "alice", state: .running),
                    ]
                )
            ],
            templateString: DefaultPrompts.eventPrompt
        )
        let prompt = try #require(result.agentPrompt)
        #expect(prompt.contains("merge the default branch"))
        // Sanity: the unrelated `pr_state_changed` branch must not have rendered.
        #expect(!prompt.contains("react to the new state"))
        // The `{%- ... -%}` whitespace controls should produce a flat, three-paragraph
        // output without spurious blank lines from the multi-line template source.
        let expected = """
        A Graftty automated team event was just delivered to you.

        This event is about your own worktree.

        Your branch's mergeability against the default branch changed. If your branch can no longer merge cleanly, merge the default branch into your branch and resolve any conflicts before continuing.

        PR #42 mergability: clean → dirty
        """
        #expect(prompt == expected)
    }

    @Test func teamSessionPromptAndTeamPromptAreIndependent() {
        let defaults = UserDefaults(suiteName: "AgentTeamsPaneTests-3")!
        defaults.removePersistentDomain(forName: "AgentTeamsPaneTests-3")
        defaults.set("session", forKey: "teamSessionPrompt")
        defaults.set("event",   forKey: "teamPrompt")
        #expect(defaults.string(forKey: "teamSessionPrompt") == "session")
        #expect(defaults.string(forKey: "teamPrompt") == "event")
    }
}
