// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("MOUSE — pending specs")
struct MouseTodo {
    @Test("""
@spec MOUSE-1.1: When libghostty requests a new mouse cursor shape via `MOUSE_SHAPE`, the application shall map the shape to the closest `NSCursor` and apply it to the targeted surface view.
""", .disabled("not yet implemented"))
    func mouse_1_1() async throws { }

    @Test("""
@spec MOUSE-1.2: When libghostty requests cursor visibility change via `MOUSE_VISIBILITY`, the application shall hide or show the system cursor, using a reference-counted pair of `NSCursor.hide()` / `NSCursor.unhide()` so repeated HIDDEN events do not leak into permanent invisibility.
""", .disabled("not yet implemented"))
    func mouse_1_2() async throws { }

    @Test("""
@spec MOUSE-1.3: When a terminal pane is destroyed while its cursor is hidden, the application shall unhide the cursor as part of teardown so the destroyed pane cannot leave the cursor invisible.
""", .disabled("not yet implemented"))
    func mouse_1_3() async throws { }

    @Test("""
@spec MOUSE-1.4: When libghostty fires `OPEN_URL` in response to a user gesture on a detected URL (e.g., Cmd-click), the application shall open the URL using `NSWorkspace.shared.open`.
""", .disabled("not yet implemented"))
    func mouse_1_4() async throws { }
}
