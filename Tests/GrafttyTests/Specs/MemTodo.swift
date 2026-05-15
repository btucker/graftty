// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("MEM — pending specs")
struct MemTodo {
    @Test("""
@spec MEM-1.6: When the LRU budget evicts a worktree's surfaces, the application shall capture each evicted pane's current grid size (columns, rows, pixel width, pixel height) for use on subsequent re-attach.
""", .disabled("not yet implemented"))
    func mem_1_6() async throws { }

    @Test("""
@spec MEM-1.7: When a previously-evicted pane is re-attached via the rehydration path, the application shall spawn its outer `zmx attach` PTY with `initialSize` equal to the captured grid size, so the underlying shell PTY winsize remains stable across the evict / re-attach cycle.
""", .disabled("not yet implemented"))
    func mem_1_7() async throws { }

    @Test("""
@spec MEM-1.8: When a previously-evicted pane is re-attached via the rehydration path, the application shall pre-size the new libghostty surface to the captured pixel dimensions before starting its host-managed backend, so the first post-layout resize event is a no-op when the layout container has not changed.
""", .disabled("not yet implemented"))
    func mem_1_8() async throws { }

    @Test("""
@spec MEM-1.9: When a previously-evicted pane is destroyed (rather than re-attached), the application shall drop its captured grid size from the cache.
""", .disabled("not yet implemented"))
    func mem_1_9() async throws { }
}
