// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("STATE — pending specs")
struct StateTodo {
    @Test("""
@spec STATE-1.1: Each worktree entry shall have one of three states: closed, running, or stale.
""", .disabled("not yet implemented"))
    func state_1_1() async throws { }

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
@spec STATE-2.2: While a pane row has a pane-scoped attention overlay, the sidebar shall replace *that pane's* title text with the overlay's text rendered in a red capsule. Sibling pane rows are unaffected.
""", .disabled("not yet implemented"))
    func state_2_2() async throws { }

    @Test("""
@spec STATE-2.4: When the user clicks a worktree entry that has any attention overlay (worktree-scoped or pane-scoped on any of its panes), the application shall clear all attention overlays on that worktree.
""", .disabled("not yet implemented"))
    func state_2_4() async throws { }

    @Test("""
@spec STATE-2.5: When the CLI sends a clear message for a worktree, the application shall clear the worktree-scoped attention overlay. Pane-scoped overlays are not affected by CLI clear messages; they auto-clear on their own timers.
""", .disabled("not yet implemented"))
    func state_2_5() async throws { }

    @Test("""
@spec STATE-2.6: When an attention overlay was set with an auto-clear duration, the application shall clear that overlay after the duration elapses, unless by then the overlay has already been cleared or replaced by a newer notification. Pane-scoped overlay timers are independent per pane.
""", .disabled("not yet implemented"))
    func state_2_6() async throws { }

    @Test("""
@spec STATE-2.7: When a pane is removed from a worktree (user close, shell exit, or migration to a different worktree via `PWD-x.x`), the application shall drop that pane's pane-scoped attention entry from the source worktree.
""", .disabled("not yet implemented"))
    func state_2_7() async throws { }

    @Test("""
@spec STATE-2.8: If a notify request specifies an auto-clear duration of zero or negative, then the application shall treat the notification as having no auto-clear timer (the overlay persists until cleared by the CLI or replaced by another notification).
""", .disabled("not yet implemented"))
    func state_2_8() async throws { }

    @Test("""
@spec STATE-2.10: When the application receives a `notify` message over the socket whose text is longer than 200 Character (grapheme cluster) units, the application shall silently drop the message rather than render or persist a blob the sidebar capsule cannot display cleanly. This backs up the CLI's `ATTN-1.10` validation for non-CLI socket clients (raw `nc -U`, web surface, custom scripts).
""", .disabled("not yet implemented"))
    func state_2_10() async throws { }

    @Test("""
@spec STATE-2.11: When the user triggers Stop on a running worktree (`TERM-1.2`'s companion — tears down all panes at once while preserving the split tree for re-open), the application shall drop every pane-scoped attention entry on that worktree. Extends `STATE-2.7`'s per-pane rule to the all-panes-at-once case. Without this, a stale pane attention badge from before the Stop would reappear on the fresh pane's sidebar row when the user re-opens the worktree — same-`TerminalID` leaves are reused on re-open to preserve layout, so the attention dictionary must be cleared explicitly. The worktree-level `attention` slot (CLI-notify) is left untouched — it's a worktree-wide concern independent of which panes are alive.
""", .disabled("not yet implemented"))
    func state_2_11() async throws { }
}
