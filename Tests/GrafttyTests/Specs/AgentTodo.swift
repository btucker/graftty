// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("AGENT — pending specs")
struct AgentTodo {
    @Test("""
@spec AGENT-6.166: When a graphical agent session advertises a new command list, the application shall replace that session's slash menu with the advertised names, descriptions, and argument hints.
""", .disabled("not yet implemented"))
    func composerUsesSessionCommandList() async throws { }

    @Test("""
@spec AGENT-6.167: When the user chooses a slash command in the graphical composer, the application shall insert its invocation into the editable draft and wait for the user to send it.
""", .disabled("not yet implemented"))
    func choosingCommandEditsDraft() async throws { }

    @Test("""
@spec AGENT-6.168: When the user sends a slash command from a graphical agent tab on Mac or GrafttyMobile, the application shall deliver the draft's exact command text and arguments to that tab's bound session.
""", .disabled("not yet implemented"))
    func sendTargetsBoundSession() async throws { }
}
