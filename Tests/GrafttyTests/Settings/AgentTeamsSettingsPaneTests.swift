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

    @Test func teamSessionPromptAndTeamPromptAreIndependent() {
        let defaults = UserDefaults(suiteName: "AgentTeamsPaneTests-3")!
        defaults.removePersistentDomain(forName: "AgentTeamsPaneTests-3")
        defaults.set("session", forKey: "teamSessionPrompt")
        defaults.set("event",   forKey: "teamPrompt")
        #expect(defaults.string(forKey: "teamSessionPrompt") == "session")
        #expect(defaults.string(forKey: "teamPrompt") == "event")
    }
}
