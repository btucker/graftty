// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("AGENT — pending specs")
struct AgentTodo {
    @Test("""
@spec AGENT-1.1: When the registry refreshes, the application shall key each claude session's busy/idle status by the `ZMX_SESSION` it inherited from its Graftty pane.
""", .disabled("not yet implemented"))
    func agent_1_1() async throws { }

    @Test("""
@spec AGENT-1.2: If a claude session reports no `ZMX_SESSION` (it is not running inside a Graftty pane), then the application shall omit it from the liveness map.
""", .disabled("not yet implemented"))
    func agent_1_2() async throws { }

    @Test("""
@spec AGENT-1.3: If a session's `ZMX_SESSION` matches no live pane, then the application shall ignore it.
""", .disabled("not yet implemented"))
    func agent_1_3() async throws { }

    @Test("""
@spec AGENT-1.4: When multiple claude sessions resolve to the same pane, the application shall report that pane as busy if any of its sessions is busy.
""", .disabled("not yet implemented"))
    func agent_1_4() async throws { }

    @Test("""
@spec AGENT-2.1: While a pane has a live `notify` attention ping, the application shall render that ping in preference to any derived busy/idle status.
""", .disabled("not yet implemented"))
    func agent_2_1() async throws { }

    @Test("""
@spec AGENT-2.2: While a pane has no live attention ping, the application shall render `working…` when its claude session is busy and render nothing when it is idle.
""", .disabled("not yet implemented"))
    func agent_2_2() async throws { }

    @Test("""
@spec AGENT-2.3: If the `claude agents --json` invocation fails or returns unparseable output, then the application shall produce an empty liveness map without crashing.
""", .disabled("not yet implemented"))
    func agent_2_3() async throws { }

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
