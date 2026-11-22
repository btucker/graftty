// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("AGENT — pending specs")
struct AgentTodo {
    @Test("""
@spec AGENT-6.168: When the user sends a slash command from an agent tab's Chat view on Mac or GrafttyMobile, the application shall deliver the draft's exact command text and arguments to that tab's bound session.
""", .disabled("not yet implemented"))
    func sendTargetsBoundSession() async throws { }

    @Test("""
@spec AGENT-6.169: When a user switches a supported running agent tab between Chat and Terminal on Mac or GrafttyMobile, the application shall keep the same tab, terminal session, provider process, assignment, and conversation in both directions.
""", .disabled("not yet implemented"))
    func switchKeepsRunningAgent() async throws { }

    @Test("""
@spec AGENT-6.170: When a user switches views during a turn, the application shall continue displaying that turn in the selected view and show each submitted message exactly once.
""", .disabled("not yet implemented"))
    func switchDuringTurnShowsSameConversation() async throws { }

    @Test("""
@spec AGENT-6.171: When a user switches views with a provider request pending, the application shall preserve the request for an explicit answer and remove its action from Chat once the provider resolves it.
""", .disabled("not yet implemented"))
    func switchPreservesPendingRequest() async throws { }

    @Test("""
@spec AGENT-6.172: When a user switches views with unsent input, the application shall preserve each view's draft in its original input field without submitting it.
""", .disabled("not yet implemented"))
    func switchPreservesUnsentInput() async throws { }

    @Test("""
@spec AGENT-6.173: When a paired viewer selects Chat or Terminal, the application shall change only that viewer's presentation and preserve the session's input ownership.
""", .disabled("not yet implemented"))
    func switchingViewsDoesNotTakeControl() async throws { }
}
