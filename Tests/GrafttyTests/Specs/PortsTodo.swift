// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("PORTS — pending specs")
struct PortsTodo {
    @Test("""
@spec PORTS-1.1: When a pane's foreground process is non-shell, the application shall scan that process subtree's TCP listening sockets every 2 seconds.
""", .disabled("not yet implemented"))
    func ports_1_1() async throws { }

    @Test("""
@spec PORTS-1.2: While a pane's foreground process is the shell, the application shall not invoke `lsof` for that pane.
""", .disabled("not yet implemented"))
    func ports_1_2() async throws { }

    @Test("""
@spec PORTS-1.3: When the previous scan tick has not completed, the application shall drop the next scheduled tick rather than queue it.
""", .disabled("not yet implemented"))
    func ports_1_3() async throws { }

    @Test("""
@spec PORTS-1.4: When `lsof` exits non-zero or is not found on `PATH`, the application shall log once and treat the snapshot as empty for that tick.
""", .disabled("not yet implemented"))
    func ports_1_4() async throws { }

    @Test("""
@spec PORTS-2.1: When a single PID binds the same port on both an IPv4 and IPv6 address, the application shall represent the result as a single `PortBinding`.
""", .disabled("not yet implemented"))
    func ports_2_1() async throws { }

    @Test("""
@spec PORTS-2.2: If any binding for a `(pid, port)` pair is on a non-loopback address, then the application shall classify that binding's scope as `.lan`.
""", .disabled("not yet implemented"))
    func ports_2_2() async throws { }

    @Test("""
@spec PORTS-2.3: When multiple PIDs bind the same `(port, scope)` (forked workers), the application shall represent the result as a single `PortBinding` whose `pid` is the lowest matching PID.
""", .disabled("not yet implemented"))
    func ports_2_3() async throws { }

    @Test("""
@spec PORTS-3.2: When `PortChip` icons render, the application shall use SF Symbol `personalhotspot` for `.loopback` scope and `globe` for `.lan` scope.
""", .disabled("not yet implemented"))
    func ports_3_2() async throws { }

    @Test("""
@spec PORTS-3.3: When chips would overflow the available width, the application shall wrap chips to the next line aligned under the pane title text rather than flush with the row's leading edge.
""", .disabled("not yet implemented"))
    func ports_3_3() async throws { }

    @Test("""
@spec PORTS-4.1: When a pane is registered, the application shall include it in subsequent scan ticks until it is unregistered.
""", .disabled("not yet implemented"))
    func ports_4_1() async throws { }

    @Test("""
@spec PORTS-4.2: When a pane is unregistered, the application shall drop its cached binding snapshot.
""", .disabled("not yet implemented"))
    func ports_4_2() async throws { }

    @Test("""
@spec PORTS-4.3: When a pane is dragged to another worktree, the application shall preserve its registration and binding snapshot (`TerminalID` is stable).
""", .disabled("not yet implemented"))
    func ports_4_3() async throws { }

    @Test("""
@spec PORTS-4.4: When a scan returns no listeners for a pane that previously had bindings, the application shall clear that pane's bindings on the same tick.
""", .disabled("not yet implemented"))
    func ports_4_4() async throws { }
}
