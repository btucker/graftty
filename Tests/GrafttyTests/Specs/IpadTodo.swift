// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("IPAD — pending specs")
struct IpadTodo {
    @Test("""
@spec IPAD-1.1: When `horizontalSizeClass == .regular`, the iPad application shall render `IPadRootLayout` (NavigationSplitView, 2-column) in place of the compact-width `NavigationStack`.
""", .disabled("not yet implemented"))
    func ipad_1_1() async throws { }

    @Test("""
@spec IPAD-1.2: While `IPadRootLayout` is presented, the sidebar shall display a `HostHeaderRow` at the top showing the selected host's label and a tap target presenting a host-switcher popover.
""", .disabled("not yet implemented"))
    func ipad_1_2() async throws { }

    @Test("""
@spec IPAD-1.3: While `IPadRootLayout` is presented, the sidebar shall render `WorktreeListContent` extracted from `WorktreePickerView`, bound to `WorktreePanesStore`, preserving `WorktreePickerGrouping`, swipe actions, PR badges, attention pills, and divergence gutter.
""", .disabled("not yet implemented"))
    func ipad_1_3() async throws { }

    @Test("""
@spec IPAD-1.4: When the user taps a pane child row in the sidebar at iPad regular width, the application shall set `IPadAppState.focusedPaneId` to that leaf's `sessionName` without pushing a new navigation stack frame.
""", .disabled("not yet implemented"))
    func ipad_1_4() async throws { }
}
