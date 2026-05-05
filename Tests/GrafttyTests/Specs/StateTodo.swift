// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("STATE — pending specs")
struct StateTodo {
    @Test("""
@spec STATE-1.2: While a worktree entry is in the closed state, the sidebar shall display its type icon (house for the main checkout, branch for linked worktrees) in a dimmed foreground color.
""", .disabled("not yet implemented"))
    func state_1_2() async throws { }

    @Test("""
@spec STATE-1.3: While a worktree entry is in the running state, the sidebar shall display its type icon tinted green.
""", .disabled("not yet implemented"))
    func state_1_3() async throws { }

    @Test("""
@spec STATE-1.4: While a worktree entry is in the stale state, the sidebar shall display its type icon tinted yellow, with strikethrough text and grayed-out appearance on the label.
""", .disabled("not yet implemented"))
    func state_1_4() async throws { }

    @Test("""
@spec STATE-2.1: A worktree entry in any state may additionally have a worktree-scoped attention overlay, and each of its panes may additionally have a pane-scoped attention overlay keyed by pane. Worktree-scoped overlays are driven by the CLI (`ATTN-1.x`); pane-scoped overlays are driven by per-pane shell-integration events (`NOTIF-2.x`).
""", .disabled("not yet implemented"))
    func state_2_1() async throws { }

    @Test("""
@spec STATE-2.4: When the user clicks a worktree entry that has any attention overlay (worktree-scoped or pane-scoped on any of its panes), the application shall clear all attention overlays on that worktree.
""", .disabled("not yet implemented"))
    func state_2_4() async throws { }

    @Test("""
@spec STATE-2.5: When the CLI sends a clear message for a worktree, the application shall clear the worktree-scoped attention overlay. Pane-scoped overlays are not affected by CLI clear messages; they auto-clear on their own timers.
""", .disabled("not yet implemented"))
    func state_2_5() async throws { }

    @Test("""
@spec STATE-2.7: When a pane is removed from a worktree (user close, shell exit, or migration to a different worktree via `PWD-x.x`), the application shall drop that pane's pane-scoped attention entry from the source worktree.
""", .disabled("not yet implemented"))
    func state_2_7() async throws { }

}
