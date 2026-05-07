// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("PORTS — pending specs")
struct PortsTodo {
    @Test("""
@spec PORTS-1.2: While a pane's foreground process is the shell, the application shall not invoke `lsof` for that pane.
""", .disabled("not yet implemented"))
    func ports_1_2() async throws { }
}
