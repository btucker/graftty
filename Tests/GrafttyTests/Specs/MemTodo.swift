// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("MEM — pending specs")
struct MemTodo {
    @Test("""
@spec MEM-1.9: When a previously-evicted pane is destroyed (rather than re-attached), the application shall drop its captured grid size from the cache.
""", .disabled("not yet implemented"))
    func mem_1_9() async throws { }
}
