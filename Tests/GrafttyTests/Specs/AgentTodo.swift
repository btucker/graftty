// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("AGENT — pending specs")
struct AgentTodo {
    @Test("""
@spec AGENT-3.1: When an agent-stop event carries a `paneSessionName` resolving to a live pane, the application shall attach the "needs input" attention to that pane rather than the worktree.
""", .disabled("not yet implemented"))
    func agent_3_1() async throws { }

    @Test("""
@spec AGENT-3.2: If an agent-stop event has no pane session (the agent is not in a Graftty pane), then the application shall fall back to worktree-scoped "needs input" attention.
""", .disabled("not yet implemented"))
    func agent_3_2() async throws { }

    @Test("""
@spec AGENT-4.1: When `graftty notify` is given `--session <zmx-session>`, the application shall target that pane's attention overlay.
""", .disabled("not yet implemented"))
    func agent_4_1() async throws { }

    @Test("""
@spec AGENT-4.2: When `graftty notify` is given no target and `$ZMX_SESSION` is set, the application shall target the caller's pane.
""", .disabled("not yet implemented"))
    func agent_4_2() async throws { }

    @Test("""
@spec AGENT-4.3: When `graftty notify` is given no target and `$ZMX_SESSION` is unset, the application shall target the current worktree (unchanged behavior).
""", .disabled("not yet implemented"))
    func agent_4_3() async throws { }

    @Test("""
@spec AGENT-4.4: If `graftty notify` is given both `--session` and `--worktree`, then the application shall reject the invocation with a validation error.
""", .disabled("not yet implemented"))
    func agent_4_4() async throws { }
}
