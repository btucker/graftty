// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("NOTIF — pending specs")
struct NotifTodo {
    @Test("""
@spec NOTIF-1.1: When libghostty fires `DESKTOP_NOTIFICATION` (OSC 9), the application shall post a banner notification via `UNUserNotificationCenter` using the title and body provided.
""", .disabled("not yet implemented"))
    func notif_1_1() async throws { }

    @Test("""
@spec NOTIF-1.2: If notification authorization has not yet been determined, the application shall request authorization on the first notification and post once authorization is granted.
""", .disabled("not yet implemented"))
    func notif_1_2() async throws { }

    @Test("""
@spec NOTIF-1.3: If the user has denied notification authorization, the application shall silently skip the notification rather than surfacing an error.
""", .disabled("not yet implemented"))
    func notif_1_3() async throws { }

    @Test("""
@spec NOTIF-2.1: When libghostty fires `COMMAND_FINISHED` with a zero exit code on a pane, the application shall set *that pane's* pane-scoped attention overlay to a checkmark indicator that auto-clears after 3 seconds. Sibling panes in the same worktree are unaffected.
""", .disabled("not yet implemented"))
    func notif_2_1() async throws { }

    @Test("""
@spec NOTIF-2.2: When libghostty fires `COMMAND_FINISHED` with a non-zero exit code on a pane, the application shall set *that pane's* pane-scoped attention overlay to an error indicator that auto-clears after 8 seconds. Sibling panes in the same worktree are unaffected.
""", .disabled("not yet implemented"))
    func notif_2_2() async throws { }

    @Test("""
@spec NOTIF-2.3: Auto-populated attention overlays from shell-integration events shall share the clearing semantics defined in STATE-2.x; a subsequent event on the same pane replaces that pane's previous overlay without affecting sibling panes' overlays.
""", .disabled("not yet implemented"))
    func notif_2_3() async throws { }
}
