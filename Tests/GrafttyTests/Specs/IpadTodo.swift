// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("IPAD — pending specs")
struct IpadTodo {
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
@spec IPAD-2.4: When `MultiPaneDetailView` renders a `.leaf(sessionName, …)`, the application shall render a `PaneLeafView` that owns its own SSH terminal session channel (one `TerminalSessionClient` per visible leaf over the shared `RemoteHostConnection`).
""", .disabled("not yet implemented"))
    func ipad_2_4() async throws { }

    @Test("""
@spec IPAD-2.5: While an iPad pane-layout leaf is not the display owner and the authoritative grid's column count exceeds the leaf's allotted width at the configured (iOS-scaled) font size, the application shall apply the same font-fit policy as `IOS-5.6` (per-leaf), rendering each leaf's pane at the full leaf width with no horizontal `ScrollView`.
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
@spec IPAD-3.5: When the user taps Swap in the toolbar, the application shall send a `pane_control` RPC with `type: "swap"`, `source` set to the focused leaf's `sessionName`, and `target` selected per the swap-target policy resolved in milestone M7 (see design doc §12 Open Question #3).
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
@spec IPAD-4.2: When opening a new `terminal` channel would exceed the IPAD-4.1 cap, the application shall close the least-recently-focused open `terminal` channel and render its leaf as an `IdleSnapshotView` placeholder.
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
@spec IPAD-5.3: When the application foregrounds, the application shall re-open the `panes_state` channel before re-opening any `terminal` channel, so the splittree shape is current before deciding which leaves to attach.
""", .disabled("not yet implemented"))
    func ipad_5_3() async throws { }

    @Test("""
@spec IPAD-5.4: When a previously-focused leaf is no longer present in the foreground-fresh `panes_state` snapshot, the application shall surface a "Pane no longer running" banner on the detail column with a "Back to sidebar" action.
""", .disabled("not yet implemented"))
    func ipad_5_4() async throws { }

    @Test("""
@spec IPAD-7.2: When `horizontalSizeClass` transitions between `.regular` and `.compact`, the application shall preserve `selectedHostId`, `selectedWorktreePath`, and `focusedPaneId` so the user lands on the equivalent leaf in the new layout.
""", .disabled("not yet implemented"))
    func ipad_7_2() async throws { }
}
