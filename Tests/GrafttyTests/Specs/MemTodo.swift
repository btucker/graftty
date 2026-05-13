// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("MEM — pending specs")
struct MemTodo {
    @Test("""
@spec MEM-1.1: While more than 4 worktrees have live surfaces, the application shall evict the least-recently-selected worktree's surfaces.
""", .disabled("not yet implemented"))
    func mem_1_1() async throws { }

    @Test("""
@spec MEM-1.3: When a worktree is stopped, removed, has its repo removed, or transitions to stale, the application shall drop it from the LRU budget.
""", .disabled("not yet implemented"))
    func mem_1_3() async throws { }

    @Test("""
@spec MEM-1.4: When a worktree whose surfaces were evicted is re-selected, the application shall re-create its surfaces via the same rehydration path used at cold launch.
""", .disabled("not yet implemented"))
    func mem_1_4() async throws { }
}
