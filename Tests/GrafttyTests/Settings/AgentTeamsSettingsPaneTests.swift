import Testing
import SwiftUI
import GrafttyKit
@testable import Graftty

@Suite("AgentTeamsSettingsPane Tests")
struct AgentTeamsSettingsPaneTests {

    @Test func defaultSessionPromptIsEmptyAndEventPromptIsNonEmpty() {
        #expect(DefaultPrompts.sessionPrompt.isEmpty)
        #expect(!DefaultPrompts.eventPrompt.isEmpty)
    }

    /// The generated team primer already names the branch, worktree, commands,
    /// and routing model. The default session template stays empty so it does
    /// not add a second role/policy paragraph at session start.
    @Test func defaultSessionPromptDoesNotDuplicateGeneratedPrimer() {
        let p = DefaultPrompts.sessionPrompt
        #expect(p.isEmpty)
        #expect(!p.contains("agent.branch"))
        #expect(!p.contains("agent.lead"))
        #expect(!p.contains("coworker"))
        #expect(!p.contains("team's lead"))
    }

    /// Per-event prompt runs per delivery and should react to whether the
    /// event concerns the agent's own worktree.
    @Test func eventPromptUsesEventScopedVariables() {
        let p = DefaultPrompts.eventPrompt
        #expect(p.contains("agent.this_worktree") || p.contains("agent.other_worktree"))
    }

    /// Catches Stencil syntax errors in the per-event default across the four
    /// agent shapes a real delivery could produce. The default session prompt
    /// is intentionally empty and therefore renders to nil.
    @Test func defaultPromptsRenderUnderEveryAgentContext() {
        let shapes: [(isMainWorktree: Bool, thisWorktree: Bool, otherWorktree: Bool)] = [
            (true,  false, false),
            (false, true,  false),
            (false, false, true ),
            (false, false, false),
        ]
        for s in shapes {
            let ctx = EventBodyRenderer.makeAgentContext(
                branch: "b",
                isMainWorktree: s.isMainWorktree,
                thisWorktree: s.thisWorktree,
                otherWorktree: s.otherWorktree
            )
            #expect(EventBodyRenderer.renderAgentTemplate(DefaultPrompts.sessionPrompt, agent: ctx) == nil)
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

    @Test("""
    @spec TEAM-1.13: When the user activates "Restore Graftty Default" for either Agent Teams prompt editor, the application shall remove the corresponding persistent `UserDefaults` key so the registered default becomes visible and later built-in updates continue to apply.
    """)
    func restoreButtonsRemoveOverridesAndRevealRegisteredDefaults() {
        let suite = "AgentTeamsPaneTests-Restore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.register(defaults: DefaultPrompts.registrations)
        defaults.set("custom session", forKey: SettingsKeys.teamSessionPrompt)
        defaults.set("custom event", forKey: SettingsKeys.teamPrompt)

        DefaultPrompts.restoreSessionPrompt(in: defaults)
        DefaultPrompts.restoreEventPrompt(in: defaults)

        #expect(defaults.string(forKey: SettingsKeys.teamSessionPrompt) == DefaultPrompts.sessionPrompt)
        #expect(defaults.string(forKey: SettingsKeys.teamPrompt) == DefaultPrompts.eventPrompt)
        let persisted = defaults.persistentDomain(forName: suite) ?? [:]
        #expect(persisted[SettingsKeys.teamSessionPrompt] == nil)
        #expect(persisted[SettingsKeys.teamPrompt] == nil)
    }
}
