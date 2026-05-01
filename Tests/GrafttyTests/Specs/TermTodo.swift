// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("TERM — pending specs")
struct TermTodo {
    @Test("""
@spec TERM-1.1: When the user clicks a worktree entry in the closed state that has no saved split tree, the application shall create a single terminal pane with its working directory set to the worktree path and transition the entry to the running state.
""", .disabled("not yet implemented"))
    func term_1_1() async throws { }

    @Test("""
@spec TERM-1.2: When the user clicks a worktree entry in the closed state that has a saved split tree, the application shall recreate terminal panes matching the saved split tree topology, each with its working directory set to the worktree path, and transition the entry to the running state.
""", .disabled("not yet implemented"))
    func term_1_2() async throws { }

    @Test("""
@spec TERM-1.3: When the user triggers Stop on a running worktree that has processes which need quit-confirmation, the application shall present a confirmation dialog whose informative text identifies the worktree by its sidebar display name (per `WorktreeEntry.displayName(amongSiblingPaths:)` / `LAYOUT-2.15`), not its raw `branch` value. For worktrees on a detached HEAD or other git sentinel (`(detached)`, `(bare)`, `(unknown)` — see `PR-7.3`), the display name resolves to the directory basename, which reads naturally ("running processes in my-feature") whereas the raw branch would render as "running processes in (detached)".
""", .disabled("not yet implemented"))
    func term_1_3() async throws { }

    @Test("""
@spec TERM-2.1: When the user switches from one running worktree to another, the application shall hide the previous worktree's terminal views without destroying the terminal surfaces or their running processes.
""", .disabled("not yet implemented"))
    func term_2_1() async throws { }

    @Test("""
@spec TERM-2.2: When the user switches back to a previously running worktree, the application shall restore the terminal views with all processes still running.
""", .disabled("not yet implemented"))
    func term_2_2() async throws { }

    @Test("""
@spec TERM-2.3: When the user switches back to a running worktree, the application shall restore keyboard focus to the pane that was focused when the user last switched away.
""", .disabled("not yet implemented"))
    func term_2_3() async throws { }

    @Test("""
@spec TERM-2.4: When the user clicks directly on a terminal pane's view (independent of the sidebar pane-row), the application shall persist that pane as the worktree's last-focused pane in the same model field that `TERM-2.3` reads on return. A visual-only focus change (libghostty / NSView side) without a matching model update would let focus snap back to the first leaf on the next return visit.
""", .disabled("not yet implemented"))
    func term_2_4() async throws { }

    @Test("""
@spec TERM-2.5: When the selected worktree changes, the application shall call `ghostty_surface_set_occlusion(surface, false)` for surfaces in the old selected worktree and `ghostty_surface_set_occlusion(surface, true)` followed by `ghostty_surface_refresh(surface)` for surfaces in the newly selected worktree. The boolean passed to `ghostty_surface_set_occlusion` is Ghostty's `visible` flag, not an `occluded` flag. When a terminal pane's `SurfaceViewWrapper` is mounted, focused, resized, or receives keyboard input, the application shall also mark the surface visible and refresh it so libghostty performs a full clean repaint of the current state. The application shall not derive hidden state directly from SwiftUI `.onDisappear`, because transient unmount/remount callbacks can race with focus and attach. If SwiftUI/AppKit reports a collapsed zero- or sub-pixel resize, then the application shall ignore that resize rather than forwarding a one-pixel size to libghostty, so background output does not accumulate scrollback wrapped at one column while the pane is hidden.
""", .disabled("not yet implemented"))
    func term_2_5() async throws { }

    @Test("""
@spec TERM-2.6: On application restart, persisted `.running` worktrees shall be marked as rehydrated but only the currently-selected worktree shall immediately recreate libghostty surfaces and run `zmx attach`. Other running worktrees shall attach lazily when selected. This keeps hidden panes from rendering or reattaching while they are not displayed, and prevents a large saved workspace from delaying input in the pane the user is actually returning to.
""", .disabled("not yet implemented"))
    func term_2_6() async throws { }

    @Test("""
@spec TERM-3.1: When the user triggers a horizontal split, the application shall insert a new terminal pane to the right of the focused pane with a 50/50 ratio.
""", .disabled("not yet implemented"))
    func term_3_1() async throws { }

    @Test("""
@spec TERM-3.2: When the user triggers a vertical split, the application shall insert a new terminal pane below the focused pane with a 50/50 ratio.
""", .disabled("not yet implemented"))
    func term_3_2() async throws { }

    @Test("""
@spec TERM-3.3: The new terminal pane created by a split shall have its working directory set to the worktree root path.
""", .disabled("not yet implemented"))
    func term_3_3() async throws { }

    @Test("""
@spec TERM-4.1: The application shall display a draggable divider between split panes.
""", .disabled("not yet implemented"))
    func term_4_1() async throws { }

    @Test("""
@spec TERM-4.2: When the user drags a divider, the application shall resize the adjacent panes so that the divider tracks the cursor's position inside the enclosing split container.
""", .disabled("not yet implemented"))
    func term_4_2() async throws { }

    @Test("""
@spec TERM-4.3: When the user releases a divider drag, the application shall persist the new ratio in the worktree's split tree so that the layout survives app restarts. Intermediate positions during the drag need not be persisted.
""", .disabled("not yet implemented"))
    func term_4_3() async throws { }

    @Test("""
@spec TERM-4.4: When a pane is removed from the split tree, the application shall forward the new layout size to libghostty so remaining panes reflow to fill the vacated space.
""", .disabled("not yet implemented"))
    func term_4_4() async throws { }

    @Test("""
@spec TERM-5.1: When the user closes a terminal pane, the application shall remove it from the split tree and allow the sibling pane to fill the vacated space.
""", .disabled("not yet implemented"))
    func term_5_1() async throws { }

    @Test("""
@spec TERM-5.2: When the user closes the last terminal pane in a worktree, the application shall transition the worktree entry to the closed state.
""", .disabled("not yet implemented"))
    func term_5_2() async throws { }

    @Test("""
@spec TERM-5.4: When an auto-closed pane was the last pane in its worktree, the application shall transition the worktree entry to the closed state, matching the user-initiated close behavior.
""", .disabled("not yet implemented"))
    func term_5_4() async throws { }

    @Test("""
@spec TERM-5.5: If `ghostty_surface_new` returns null (libghostty resource exhaustion, malformed config, or any internal rejection) when the application tries to create a terminal surface, the application shall skip the failed leaf and propagate a nil result to the caller rather than trap via `fatalError`. Callers shall treat nil as "surface creation failed": `splitPane` shall roll back its split-tree mutation so no dangling leaf is left behind; `addPane` (CLI `graftty pane add`) shall return a socket `.error("split failed")`; `createSurfaces` (worktree open) shall leave the leaf's surface dict entry empty so the view renders the `Color.black + ProgressView` fallback without crashing the app. Observed pre-fix: `graftty pane add --command ...` triggered a SIGTRAP inside `SurfaceHandle.init` whenever libghostty couldn't build the surface.
""", .disabled("not yet implemented"))
    func term_5_5() async throws { }

    @Test("""
@spec TERM-5.6: When a terminal pane is removed (user close via Cmd+W, shell exit, CLI `graftty pane close`), the application shall promote `focusedTerminalID` to `remainingTree.allLeaves.first` ONLY if the removed pane was the currently-focused one. If a different pane was focused, `focusedTerminalID` shall stay on that pane — it's still present in the remaining tree, and the user's keystrokes should continue to route there. Pre-fix behavior (unconditional promotion to the first leaf) silently jumped focus whenever the user closed a pane other than their focused one, mirroring Andy's "furious when any tool kills a long-running shell unexpectedly" pain point in the focus-redirection dimension.
""", .disabled("not yet implemented"))
    func term_5_6() async throws { }

    @Test("""
@spec TERM-5.7: When libghostty's `close_surface_cb` fires for a pane whose `SurfaceHandle` has already been torn down by Graftty (e.g. via `terminalManager.destroySurfaces(...)` during a `Stop Worktree` action), the application's close-event handler shall observe the missing surface handle and no-op rather than modifying the worktree's `splitTree`. Without this guard, the async close-event cascade that follows `Stop` would re-enter `closePane` for each leaf and strip them from the preserved split tree, emptying `splitTree` and violating `TERM-1.2`'s "re-open recreates the saved layout" contract. The guard applies only to library-initiated close events; user-initiated closes are covered by `TERM-5.8`.
""", .disabled("not yet implemented"))
    func term_5_7() async throws { }

    @Test("""
@spec TERM-5.9: When `SurfaceHandle.setFrameSize` forwards a backing-pixel dimension to `ghostty_surface_set_size`, the conversion from `CGFloat` to `UInt32` shall be performed via a defensive clamp that maps `NaN` and values `≤ 1` to `1`, `+∞` and values `≥ UInt32.max` to `UInt32.max`, and all other finite values to their truncated `UInt32` representation. Naive `UInt32(max(1, Int(dim)))` traps on `NaN` and on out-of-`Int`-range values; SwiftUI `GeometryReader` has been observed to emit `.infinity` transiently during certain rebinding flows, and a trap on the view's layout pass crashes the whole process (every open pane dies). The helper is `SurfacePixelDimension.clamp(_:)` in GrafttyKit so the rule is unit-testable without an NSView host.
""", .disabled("not yet implemented"))
    func term_5_9() async throws { }

    @Test("""
@spec TERM-6.1: When the user triggers "Stop" on a running worktree, if any terminal surface has a running process, then the application shall display a confirmation dialog before proceeding.
""", .disabled("not yet implemented"))
    func term_6_1() async throws { }

    @Test("""
@spec TERM-6.2: When the user confirms stopping a worktree, the application shall close and free all terminal surfaces in the worktree's split tree, preserve the split tree topology, and transition the entry to the closed state.
""", .disabled("not yet implemented"))
    func term_6_2() async throws { }

    @Test("""
@spec TERM-7.1: When the user clicks a terminal pane, the application shall set keyboard focus to that pane.
""", .disabled("not yet implemented"))
    func term_7_1() async throws { }

    @Test("""
@spec TERM-7.2: The application shall support keyboard navigation between panes using directional shortcuts (e.g., Cmd+Opt+Arrow).
""", .disabled("not yet implemented"))
    func term_7_2() async throws { }

    @Test("""
@spec TERM-7.4: When the application launches with a selected running worktree, the application shall automatically promote that worktree's focused pane to the window's first responder so the user can begin typing without first clicking inside a terminal.
""", .disabled("not yet implemented"))
    func term_7_4() async throws { }

    @Test("""
@spec TERM-7.5: When the user selects a worktree or pane row in the sidebar, the application shall promote the target pane's `NSView` to the window's first responder so subsequent keystrokes route to that pane without an intermediate click.
""", .disabled("not yet implemented"))
    func term_7_5() async throws { }

    @Test("""
@spec TERM-7.6: When the user invokes `Previous Pane` / `Next Pane` (libghostty's `goto_split:previous` / `goto_split:next`), the application shall cycle focus through the worktree's leaves in DFS (reading) order regardless of spatial layout. This is distinct from the directional arrow-key navigation in `TERM-7.3` — round-robin cycling is an intentional second mode, not a fallback.
""", .disabled("not yet implemented"))
    func term_7_6() async throws { }

    @Test("""
@spec TERM-7.7: When a pane is created via a split (`splitPane`), a CLI-triggered add (`pane add`), or any other path that mints a fresh `SurfaceHandle` before SwiftUI has had a chance to insert the view into the window hierarchy, the application shall still promote the new pane's `NSView` to the window's first responder — overriding the previously-focused pane whose view is still the current first responder. The implementation seam is `SurfaceHandle.setFocus(true)`: if the target view is already attached to a window, first responder is claimed synchronously; if not, the claim is re-enqueued on the main queue so it runs after SwiftUI mounts the view. Pre-fix behavior: after `Cmd+D`, the model's `focusedTerminalID`, the sidebar's focus highlight, and libghostty's focused-cursor rendering all pointed at the new pane, yet AppKit's first responder remained the previously-focused pane — so keystrokes kept landing in the old pane. `SurfaceNSView.viewDidMoveToWindow` cannot fix this on its own because its first-responder grab deliberately yields to an existing `SurfaceNSView` first responder (so an incidentally-remounted view doesn't yank focus from the user); an authoritative `setFocus(true)` call is the signal that distinguishes the two cases.
""", .disabled("not yet implemented"))
    func term_7_7() async throws { }

    @Test("""
@spec TERM-8.1: When the user right-clicks a terminal pane, the application shall display a context menu. When the user Control-clicks with the left mouse button on a terminal pane, the application shall display the same context menu, unless the terminal has enabled mouse capturing in which case the click shall be delivered to the terminal as a right-mouse-press instead.
""", .disabled("not yet implemented"))
    func term_8_1() async throws { }

    @Test("""
@spec TERM-8.2: The context menu shall contain the following items, in this order, separated by dividers as shown:
""", .disabled("not yet implemented"))
    func term_8_2() async throws { }

    @Test("""
@spec TERM-8.3: When the user selects "Copy", the application shall copy the current terminal selection to the system clipboard.
""", .disabled("not yet implemented"))
    func term_8_3() async throws { }

    @Test("""
@spec TERM-8.4: When the user selects "Paste", the application shall insert the system clipboard's text contents into the terminal.
""", .disabled("not yet implemented"))
    func term_8_4() async throws { }

    @Test("""
@spec TERM-8.5: When the user selects "Split Right", "Split Left", "Split Down", or "Split Up", the application shall create a new terminal pane adjacent to the focused pane in the corresponding direction.
""", .disabled("not yet implemented"))
    func term_8_5() async throws { }

    @Test("""
@spec TERM-8.6: When the user selects "Reset Terminal", the application shall reset the terminal's screen and state to a pristine post-init condition.
""", .disabled("not yet implemented"))
    func term_8_6() async throws { }

    @Test("""
@spec TERM-8.7: When the user selects "Toggle Terminal Inspector", the application shall toggle the display of libghostty's built-in debug inspector overlay on the terminal.
""", .disabled("not yet implemented"))
    func term_8_7() async throws { }

    @Test("""
@spec TERM-8.8: While a terminal pane is in read-only mode, the "Terminal Read-only" menu item shall display a checkmark.
""", .disabled("not yet implemented"))
    func term_8_8() async throws { }

    @Test("""
@spec TERM-8.9: When the user selects "Terminal Read-only", the application shall toggle the terminal's read-only state — in read-only mode the terminal renders updates but drops keyboard input from the user.
""", .disabled("not yet implemented"))
    func term_8_9() async throws { }

    @Test("""
@spec TERM-8.10: When the user opens the right-click context menu on a pane via `TERM-8.1`, the application shall include the Move-to-worktree items defined by `PWD-1.1`, `PWD-1.2`, and `PWD-1.3` in the position specified by `TERM-8.2`. The semantics — cwd-matching, disabled-when-no-match, same-repo-only submenu, sanitized display labels per `GIT-2.10` — are inherited from those requirements; this requirement only fixes the menu position and the surface (Ghostty terminal pane) where the items appear, mirroring what's already required on the sidebar pane row.
""", .disabled("not yet implemented"))
    func term_8_10() async throws { }

    @Test("""
@spec TERM-9.1: When the user activates "Reload Ghostty Config"
""", .disabled("not yet implemented"))
    func term_9_1() async throws { }

    @Test("""
@spec TERM-9.2: When the user activates "Open Ghostty Settings"
""", .disabled("not yet implemented"))
    func term_9_2() async throws { }
}
