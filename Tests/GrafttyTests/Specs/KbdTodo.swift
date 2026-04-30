// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("KBD — pending specs")
struct KbdTodo {
    @Test("""
@spec KBD-1.1: When the user presses a chord bound in their Ghostty config
""", .disabled("not yet implemented"))
    func kbd_1_1() async throws { }

    @Test("""
@spec KBD-1.2: When the user's Ghostty config omits a binding for an action,
""", .disabled("not yet implemented"))
    func kbd_1_2() async throws { }

    @Test("""
@spec KBD-2.1: When the user presses `toggle_split_zoom` on a focused pane
""", .disabled("not yet implemented"))
    func kbd_2_1() async throws { }

    @Test("""
@spec KBD-2.2: When the user presses `toggle_split_zoom` on a lone pane
""", .disabled("not yet implemented"))
    func kbd_2_2() async throws { }

    @Test("""
@spec KBD-2.3: When the user presses a `goto_split:*` chord while a pane is
""", .disabled("not yet implemented"))
    func kbd_2_3() async throws { }

    @Test("""
@spec KBD-3.1: When the user presses a `resize_split:<direction>` chord,
""", .disabled("not yet implemented"))
    func kbd_3_1() async throws { }

    @Test("""
@spec KBD-3.2: When no matching-orientation ancestor exists, the
""", .disabled("not yet implemented"))
    func kbd_3_2() async throws { }

    @Test("""
@spec KBD-4.1: When `reload_config` fires, the application shall rebuild
""", .disabled("not yet implemented"))
    func kbd_4_1() async throws { }
}
