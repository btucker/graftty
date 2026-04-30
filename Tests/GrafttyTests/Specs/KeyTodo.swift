// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("KEY — pending specs")
struct KeyTodo {
    @Test("""
@spec KEY-1.1: The application shall forward all keyboard input, including Command-modified keys, to libghostty so that libghostty's default keybindings (Cmd+C copy, Cmd+V paste, Cmd+A select-all, Cmd+K clear, etc.) take effect.
""", .disabled("not yet implemented"))
    func key_1_1() async throws { }

    @Test("""
@spec KEY-1.2: When libghostty reports that a key was not handled, the application shall allow the event to continue up the responder chain.
""", .disabled("not yet implemented"))
    func key_1_2() async throws { }

    @Test("""
@spec KEY-1.3: Application-level menu keyboard shortcuts (Cmd+D split, Cmd+W close pane, Cmd+O add repository, and pane navigation shortcuts) shall be matched by AppKit's menu `keyEquivalent` interception before the keyDown event reaches the terminal, so menu shortcuts override any conflicting libghostty keybinding.
""", .disabled("not yet implemented"))
    func key_1_3() async throws { }

    @Test("""
@spec KEY-2.1: When libghostty requests a clipboard write (e.g., from `Cmd+C` or the context menu Copy), the application shall write the provided content to `NSPasteboard.general`.
""", .disabled("not yet implemented"))
    func key_2_1() async throws { }

    @Test("""
@spec KEY-2.2: When libghostty requests a clipboard read (e.g., from `Cmd+V` or the context menu Paste), the application shall read from `NSPasteboard.general` and return the text via `ghostty_surface_complete_clipboard_request`.
""", .disabled("not yet implemented"))
    func key_2_2() async throws { }

    @Test("""
@spec KEY-2.3: Selection clipboard requests (X11-style primary selection) shall route to the same general pasteboard, as macOS does not provide a distinct selection clipboard.
""", .disabled("not yet implemented"))
    func key_2_3() async throws { }

    @Test("""
@spec KEY-2.4: OSC 52 read-confirmation prompts shall be declined by default for security; terminal programs requesting OSC 52 reads shall fail silently rather than succeeding without user consent.
""", .disabled("not yet implemented"))
    func key_2_4() async throws { }

    @Test("""
@spec KEY-3.1: When the user presses `⌘T` while `appState.selectedWorktreePath`
""", .disabled("not yet implemented"))
    func key_3_1() async throws { }

    @Test("""
@spec KEY-3.2: While presenting the Add Worktree sheet via `⌘T`, if the
""", .disabled("not yet implemented"))
    func key_3_2() async throws { }
}
