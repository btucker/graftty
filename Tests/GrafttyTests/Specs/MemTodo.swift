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
@spec MEM-1.2: When a worktree's surfaces are evicted via the LRU budget, the application shall preserve its zmx sessions, pane-to-session mapping, titles, PWDs, and rehydration state so re-selection re-attaches transparently.
""", .disabled("not yet implemented"))
    func mem_1_2() async throws { }

    @Test("""
@spec MEM-1.3: When a worktree is stopped, removed, has its repo removed, or transitions to stale, the application shall drop it from the LRU budget.
""", .disabled("not yet implemented"))
    func mem_1_3() async throws { }

    @Test("""
@spec MEM-1.4: When a worktree whose surfaces were evicted is re-selected, the application shall re-create its surfaces via the same rehydration path used at cold launch.
""", .disabled("not yet implemented"))
    func mem_1_4() async throws { }

    @Test("""
@spec MEM-1.5: When the LRU budget evicts a worktree, the application shall not kill its zmx sessions or fire `paneClosed` callbacks.
""", .disabled("not yet implemented"))
    func mem_1_5() async throws { }
}
