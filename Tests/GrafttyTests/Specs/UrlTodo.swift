// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("URL — pending specs")
struct UrlTodo {
    @Test("""
@spec URL-3.1: When the iOS app opens a graftty://open URL that resolves \
against the connected host's worktree-panes snapshot, the application \
shall select that worktree and focus the resolved pane session.
""", .disabled("not yet implemented — iOS .onOpenURL wiring is a follow-up"))
    func url_3_1() async throws { }

}
