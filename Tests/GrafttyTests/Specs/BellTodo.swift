// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("BELL — pending specs")
struct BellTodo {
    @Test("""
@spec BELL-1.1: When libghostty fires `RING_BELL`, the application shall play the system beep sound.
""", .disabled("not yet implemented"))
    func bell_1_1() async throws { }
}
