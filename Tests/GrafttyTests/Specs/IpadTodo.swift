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

    @Test("""
@spec IPAD-2.1: While a worktree is selected and the iPad layout is regular-width, the detail column shall render `MultiPaneDetailView` over the worktree's `PaneLayoutNode`.
""", .disabled("not yet implemented"))
    func ipad_2_1() async throws { }

    @Test("""
@spec IPAD-2.2: When `MultiPaneDetailView` renders a `.split(.horizontal, ratio, left, right)`, the application shall render an `HStack` with the two children proportionally sized by `ratio` and a draggable `Divider` between them.
""", .disabled("not yet implemented"))
    func ipad_2_2() async throws { }

    @Test("""
@spec IPAD-2.3: When `MultiPaneDetailView` renders a `.split(.vertical, ratio, left, right)`, the application shall render a `VStack` with the two children proportionally sized by `ratio` and a draggable `Divider` between them.
""", .disabled("not yet implemented"))
    func ipad_2_3() async throws { }

    @Test("""
@spec IPAD-2.4: When `MultiPaneDetailView` renders a `.leaf(sessionName, …)`, the application shall render a `PaneLeafView` that owns its own `terminal` channel via `TerminalChannelPool`.
""", .disabled("not yet implemented"))
    func ipad_2_4() async throws { }

    @Test("""
@spec IPAD-2.5: While a leaf's allotted frame width is less than `serverCols × cellWidth`, the application shall wrap the leaf's `TerminalPaneView` in a horizontal `ScrollView`, matching the per-screen logic in `TerminalWidthLayout.decide`.
""", .disabled("not yet implemented"))
    func ipad_2_5() async throws { }

    @Test("""
@spec IPAD-2.6: When `IPadAppState.focusedPaneId == leaf.sessionName`, the application shall render a 2pt focus ring around the corresponding `PaneLeafView`.
""", .disabled("not yet implemented"))
    func ipad_2_6() async throws { }

    @Test("""
@spec IPAD-2.7: When the user drags a split's divider, the application shall update a per-iPad-client divider-ratio override map keyed by the tree path to that split, without sending any RPC to the host.
""", .disabled("not yet implemented"))
    func ipad_2_7() async throws { }

    @Test("""
@spec IPAD-3.1: When `MultiPaneDetailView` has a focused leaf and the soft keyboard is hidden, the application shall overlay a `FocusedPaneToolbar` on the focused leaf containing Split Right, Split Down, Swap, and Close icons.
""", .disabled("not yet implemented"))
    func ipad_3_1() async throws { }

    @Test("""
@spec IPAD-3.2: When the soft keyboard becomes visible, the application shall hide the `FocusedPaneToolbar` and yield its position to the terminal control bar.
""", .disabled("not yet implemented"))
    func ipad_3_2() async throws { }

    @Test("""
@spec IPAD-3.3: When the user taps Split Right or Split Down in the toolbar, the application shall send a `pane_control` RPC with `type: "split"`, `target` set to the focused leaf's `sessionName`, and `direction` set to `"horizontal"` or `"vertical"` respectively.
""", .disabled("not yet implemented"))
    func ipad_3_3() async throws { }

    @Test("""
@spec IPAD-3.4: When the user taps Close in the toolbar, the application shall send a `pane_control` RPC with `type: "close"` and `target` set to the focused leaf's `sessionName`.
""", .disabled("not yet implemented"))
    func ipad_3_4() async throws { }

    @Test("""
@spec IPAD-3.5: When the user taps Swap in the toolbar, the application shall send a `pane_control` RPC with `type: "swap"`, `source` set to the focused leaf's `sessionName`, and `target` set to the previously-focused leaf's `sessionName`.
""", .disabled("not yet implemented"))
    func ipad_3_5() async throws { }

    @Test("""
@spec IPAD-3.6: When a `pane_control` RPC returns `409 Conflict`, the application shall not present an error toast and shall rely on the next `panes_state` snapshot to reflect actual server state.
""", .disabled("not yet implemented"))
    func ipad_3_6() async throws { }

    @Test("""
@spec IPAD-4.1: While the iPad layout is presented, the application shall cap concurrent open `terminal` channels at 8 leaves across all visible panes.
""", .disabled("not yet implemented"))
    func ipad_4_1() async throws { }

    @Test("""
@spec IPAD-4.2: When opening a new `terminal` channel would exceed the IPAD-4.1 cap, the application shall close the least-recently-focused open `terminal` channel and render its leaf as an `IdleSnapshotView` from the last frame the channel held.
""", .disabled("not yet implemented"))
    func ipad_4_2() async throws { }

    @Test("""
@spec IPAD-4.3: When the user taps an `IdleSnapshotView` placeholder leaf, the application shall open a fresh `terminal` channel for that leaf, potentially evicting a different least-recently-focused leaf per IPAD-4.2.
""", .disabled("not yet implemented"))
    func ipad_4_3() async throws { }

    @Test("""
@spec IPAD-4.4: When a leaf is closed (via `pane_control: close` or removed from a `panes_state` snapshot), the application shall close its `terminal` channel and drop it from the LRU budget.
""", .disabled("not yet implemented"))
    func ipad_4_4() async throws { }

    @Test("""
@spec IPAD-5.1: When the application enters the background, the application shall close all `terminal` channels, close the `panes_state` channel, close the DataChannel, and tear down the `RemoteHostConnection`.
""", .disabled("not yet implemented"))
    func ipad_5_1() async throws { }

    @Test("""
@spec IPAD-5.2: When the application foregrounds and the biometric gate is satisfied, the application shall rebuild the `RemoteHostConnection` from signaling onward, completing a fresh Noise handshake before opening any channel.
""", .disabled("not yet implemented"))
    func ipad_5_2() async throws { }

    @Test("""
@spec IPAD-5.3: When the application foregrounds, the application shall re-open the `panes_state` channel before re-opening any `terminal` channel, so the splittree shape is current before deciding which leaves to attach.
""", .disabled("not yet implemented"))
    func ipad_5_3() async throws { }

    @Test("""
@spec IPAD-5.4: When a previously-focused leaf is no longer present in the foreground-fresh `panes_state` snapshot, the application shall surface a "Pane no longer running" banner on the detail column with a "Back to sidebar" action.
""", .disabled("not yet implemented"))
    func ipad_5_4() async throws { }

    @Test("""
@spec IPAD-6.1: When the user selects a different host from the host-switcher popover, the application shall close all open channels on the current `RemoteHostConnection`, tear down the connection, and build a new `RemoteHostConnection` for the selected host.
""", .disabled("not yet implemented"))
    func ipad_6_1() async throws { }

    @Test("""
@spec IPAD-6.2: While the new `RemoteHostConnection` is establishing, the sidebar shall show the new host's label with an in-progress spinner and the detail column shall render `ContentUnavailableView`.
""", .disabled("not yet implemented"))
    func ipad_6_2() async throws { }

    @Test("""
@spec IPAD-6.3: When the new `RemoteHostConnection` completes its first `panes_state` snapshot, the application shall clear the spinner and, unless a prior selection has been restored from device state, select the first worktree in the snapshot's ordering as `IPadAppState.selectedWorktreePath`.
""", .disabled("not yet implemented"))
    func ipad_6_3() async throws { }
}
