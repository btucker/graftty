# Mobile Copy and Paste

**Date:** 2026-05-15
**Status:** Draft (design approved, awaiting plan)

## Problem

GrafttyMobile today has no way to move text between the device clipboard and the remote terminal. There is no select-to-copy gesture inside the terminal — touches pass through libghostty's pan-to-scroll, and Graftty's `UIKeyInput` proxy is hit-test transparent (`IOS-6.6`, `IOS-6.8`), so the standard UIKit edit menu never appears. Software-keyboard text deliberately bypasses libghostty's `sendText` path to avoid bracketed-paste wrappers leaking into TUI prompts (`IOS-6.6`), which means there is no paste path at all — even text on the clipboard cannot be sent to the remote PTY without being typed one keystroke at a time.

`IOS-8.2` records OSC 52 (program-initiated clipboard) as a v1 non-goal. That stance stays. The gap this design closes is the **user-initiated** clipboard surface — long-press to copy what's on the terminal, paste what's on the clipboard into the terminal.

## Goals

- A user can long-press the terminal, pick **Select**, drag to refine, and tap **Copy** to put text on the device clipboard.
- A user can long-press the terminal and tap **Paste** to send clipboard contents to the remote PTY as a single bracketed paste.
- The control bar (`IOS-6.1`) keeps its current key set — Paste lives in the long-press menu, not as another button row.
- Selection rendering and word/line semantics are reused from libghostty rather than reimplemented.

## Non-goals

- OSC 52 (`IOS-8.2` stands).
- Selection handles with drag-grip hit-testing on the highlight endpoints. v1 uses a single pan-to-extend gesture.
- A "Copy last command output" semantic action. The user can long-press → Select All if they want the viewport.
- Cross-pane selection. Selection is per-pane state.

## Design

### Flow

1. **Long-press on a focused terminal pane** → `UIEditMenuInteraction` presents at the touch point with:
   - **Select** (always)
   - **Select All** (always)
   - **Paste** (present only when `UIPasteboard.general.hasStrings` is true at menu-build time)

2. **Tap Select** → libghostty word-selects the cell under the long-press point by synthesizing a LEFT mouse-down + LEFT mouse-up pair followed by a second click within libghostty's double-click window, reusing libghostty's word-boundary semantics. The pane enters selection mode.

3. **Tap Select All** → the application invokes libghostty's `select_all` binding via `ghostty_surface_binding_action(surface, "select_all", 0)`; the pane enters selection mode with the full visible viewport highlighted.

4. **Drag inside the terminal while in selection mode** → each pan `.changed` translation is forwarded as `surface.sendMousePos(x:y:mods:)` so libghostty extends its selection live. libghostty draws the highlight using its `selection-background` config.

5. **Touch-up after extension (or immediately after Select/Select All)** → a second `UIEditMenuInteraction` presents anchored near the selection rect with **Copy** and **Cancel**.

6. **Tap Copy** → the application calls `ghostty_surface_read_selection(surface, &text)`, writes the resulting String to `UIPasteboard.general.string`, clears libghostty's selection, exits selection mode, dismisses the menu.

7. **Tap Cancel, tap outside the selection, or press a control-bar key while in selection mode** → libghostty's selection is cleared, the pane exits selection mode, the pasteboard is not touched.

8. **Tap Paste in the long-press menu** → the application reads `UIPasteboard.general.string`. If non-nil and non-empty, it is sent via `SessionClient.sendPaste(_:)`. Empty/nil clipboard is a silent no-op.

### Bracketed paste

`SessionClient.sendPaste(_:)` wraps its payload in `ESC [ 200 ~` … `ESC [ 201 ~` and emits the whole thing as a single binary WebSocket frame. The single-byte LF→CR rule of `IOS-6.3` does not apply to this path; the payload's line endings are sent verbatim so TUIs that respect bracketed paste (Claude Code, neovim, readline) can detect a paste and skip per-keystroke handling like auto-indent.

This is **the** reason `sendPaste` exists as a distinct method rather than a flag on `sendSoftwareKeyboardText`. The IOS-6.3 LF→CR rule and the IOS-6.6 bracketed-paste-stripping behavior both live in the typing pipeline and are correct there. Splitting paste into its own entry point lets each rule apply where it was designed for, without a "skip these transforms" boolean.

### Architecture

Three new units:

**`TerminalSelectionController`** — per-pane state machine. Pure logic, no SwiftUI/UIKit view imports beyond what's needed for `CGPoint`. Owns the selection-mode flag, drives a `SurfaceProxy` protocol (the libghostty surface, abstracted for testing). States: `inactive` and `active`. Methods:

```swift
func beginSelection(at point: CGPoint) -> Bool        // synthesizes word-select; true if selection took
func selectAll()                                       // invokes select_all binding action
func extend(to point: CGPoint)                         // sendMousePos
func copy(toPasteboard pb: Pasteboard) -> String?     // reads selection, writes to pb, exits mode
func cancel()                                          // clears libghostty selection, exits mode
var isActive: Bool { get }
```

`SurfaceProxy` is a protocol so tests don't need a real libghostty surface:

```swift
protocol SurfaceProxy {
    func sendMouseButton(state: GhosttyMouseState, button: GhosttyMouseButton, mods: GhosttyMods)
    func sendMousePos(x: Double, y: Double, mods: GhosttyMods)
    func bindingAction(_ name: String) -> Bool
    func readSelection() -> String?
    func clearSelection()
}
```

`Pasteboard` is similarly a protocol (`UIPasteboard.general` adopts it via extension) so the copy path can be tested without touching the system pasteboard.

**`TerminalSelectionMenuController`** — owns the two `UIEditMenuInteraction` instances (long-press menu and post-selection menu). Builds `UIEditMenuConfiguration` action providers that re-check `UIPasteboard.general.hasStrings` at present-time. Lives on `TerminalInputContainerView`.

**`SessionClient.sendPaste(_:)`** — extends the existing client. Wraps in bracketed-paste delimiters; sends as a single binary frame; no transformation of the payload's bytes.

### Gesture choreography

`TerminalInputContainerView` gains:
- A `UILongPressGestureRecognizer` attached to the container view. Fires the long-press menu. Lives at the container level so it competes correctly with libghostty's recognizers below.
- A `UIPanGestureRecognizer` for selection extension, attached to the container. Enabled iff `selectionController.isActive`. When enabled, libghostty's pan-to-scroll is disabled (we set `view.terminalView.gestureRecognizers?.forEach { $0.isEnabled = false }` filtered to libghostty's pan recognizer, or scope the toggle by setting the container's pan recognizer to require failure of the long-press).
- The `UIEditMenuInteraction` is owned by the container.

When selection mode is exited (via Copy, Cancel, outside-tap, or control-bar key), libghostty's pan is re-enabled and the container's pan is disabled.

### Per-pane state

Selection mode is per-pane state on `TerminalSelectionController`, instantiated once per `TerminalInputContainerView`. On iPad with two simultaneous panes (`IOS-5.2`), one pane can be in selection mode while the other receives keystrokes. Selection state is never lifted to a global.

### Preview panes

Worktree-detail preview panes (`IOS-4.10`, `IOS-4.12`) do not get selection. They are not focused, they are not size-leader (`IOS-4.18`), and they exist only to convey shape and activity. The long-press gesture is not installed on preview tiles. Tapping a tile still opens the fullscreen pane, where selection is available.

### Error handling

- Empty clipboard on Paste: silent no-op. No toast. (The Paste menu item won't appear when the clipboard is empty, but a race between menu build and tap is possible; we still guard.)
- Empty selection on Copy (e.g., user tapped Cancel implicitly by ending the drag at the anchor): silent no-op, mode exits, pasteboard untouched.
- WebSocket disconnected when Paste is tapped: existing `SessionClient.send` drops the frame, the existing disconnected banner (`IOS-7.4`) takes over. No new error UX.
- `ghostty_surface_read_selection` returning false / empty: treated as "no selection," same as the empty-selection case.

### Touching existing specs

- **IOS-6.1** — no change. The control bar's enumerated keys do not gain Paste.
- **IOS-6.6** — no change. Soft-keyboard text still bypasses libghostty's bracketed-paste wrapper. `sendPaste` is a separate path.
- **IOS-8.2** — no change. OSC 52 is still a non-goal.

### New @spec block: IOS-11.x — Copy and paste

- **IOS-11.1** When the user long-presses a focused terminal pane, the application shall present a `UIEditMenuInteraction` menu at the touch point containing **Select**, **Select All**, and (when `UIPasteboard.general.hasStrings` is true at menu-build time) **Paste**.
- **IOS-11.2** When the user taps **Select** in the long-press menu, the application shall ask libghostty to word-select the cell under the long-press point by synthesizing a LEFT mouse-down/up pair plus a second click within libghostty's double-click window, and shall enter selection mode for that pane.
- **IOS-11.3** When the user taps **Select All** in the long-press menu, the application shall invoke libghostty's `select_all` binding action via `ghostty_surface_binding_action(surface, "select_all", 0)` and shall enter selection mode for that pane with the visible viewport highlighted.
- **IOS-11.4** While in selection mode, the application shall extend the live selection by forwarding pan-gesture positions to `surface.sendMousePos(...)`, and libghostty's built-in pan-to-scroll recognizer on the underlying `UITerminalView` shall be disabled until selection mode exits.
- **IOS-11.5** When selection mode is active and the user lifts their finger after Select / Select All / extend, the application shall present a second `UIEditMenuInteraction` menu anchored near the selection rect containing **Copy** and **Cancel**.
- **IOS-11.6** When the user taps **Copy**, the application shall extract the active selection via `ghostty_surface_read_selection`, write the result to `UIPasteboard.general.string`, clear libghostty's selection, and exit selection mode. If `ghostty_surface_read_selection` returns no text, the pasteboard shall not be modified.
- **IOS-11.7** When the user taps **Cancel**, taps outside the highlighted selection, or presses a key on the terminal control bar while in selection mode, the application shall clear libghostty's selection and exit selection mode without modifying the pasteboard.
- **IOS-11.8** When the user taps **Paste** in the long-press menu, the application shall read `UIPasteboard.general.string` and, when non-empty, send it via `SessionClient.sendPaste(_:)`. An empty or absent clipboard string shall be a silent no-op.
- **IOS-11.9** `SessionClient.sendPaste(_:)` shall wrap the payload in `ESC [ 200 ~` and `ESC [ 201 ~` and emit the wrapped sequence as a single binary WebSocket frame. The single-byte LF→CR translation of `IOS-6.3` shall not apply to this path; the payload's own line endings shall be preserved verbatim.
- **IOS-11.10** Selection mode shall be per-pane state owned by the focused pane's `TerminalSelectionController`. Selection in one pane shall not affect the selection state of any other pane.
- **IOS-11.11** While a pane is rendered as a worktree-detail preview tile (`IOS-4.10`), the long-press selection menu shall not be installed; tapping the tile shall continue to open the fullscreen pane per `IOS-4.21`.

## Tests

- **SessionClientPasteTests** — `sendPaste("foo")` produces `ESC[200~foo ESC[201~` as a single binary frame; multi-line content with embedded LF preserved; empty payload sends nothing; verifies the IOS-6.3 LF→CR translation does NOT apply (a payload of `"\n"` arrives as `ESC[200~\nESC[201~`, not `ESC[200~\rESC[201~`).
- **SessionClientSoftKeyTests (regression)** — single-byte LF through `sendSoftwareKeyboardText` is still translated to CR per IOS-6.3.
- **TerminalSelectionControllerTests** — driven by a fake `SurfaceProxy`:
  - `beginSelection(at:)` synthesizes the libghostty mouse-event sequence (down/up + second click within window) and flips state to `.active`.
  - `selectAll()` calls `bindingAction("select_all")` and flips state to `.active`.
  - `extend(to:)` calls `sendMousePos` and stays `.active`.
  - `copy(toPasteboard:)` reads the surface selection, writes it to the injected pasteboard, calls `clearSelection`, and flips state to `.inactive`.
  - `cancel()` calls `clearSelection`, never touches the pasteboard, flips to `.inactive`.
  - `copy(toPasteboard:)` with an empty surface selection does not write to the pasteboard.
- **TerminalEditMenuTests** — verifies the long-press menu's action provider omits **Paste** when `Pasteboard.hasStrings` is false at build time, includes it when true.
- **`*Todo.swift` migration** — IOS-11.x specs land in `Tests/GrafttyTests/Specs/IosTodo.swift` as disabled placeholders for any subset that isn't covered by a real test in this PR, so `SPECS.md` lists them.

Per **CLAUDE.md** rules, `Tests/GrafttyTests/Specs/IosTodo.swift` may need to be created if it does not yet exist; otherwise the new IDs slot in.

## Risk

libghostty's iOS selection path is not exercised by anything in this app today. There is a small chance that synthesizing mouse-down → drag → mouse-up programmatically yields different selection state than AppKit's driver (AppKit uses `clickCount`, which we'd replicate by emitting the second click within the double-click window). The fallback if this misbehaves is to build a Graftty-owned selection layer using `ghostty_surface_read_text(rectangle)` and a Swift-side highlight overlay — same UX shell, more code.

## Open question (deferred, not blocking v1)

Selection across the scrollback (above the visible viewport) requires libghostty to scroll while drag is at the edge of the viewport. We do not handle this in v1; the user can only select what's currently on screen. Listed here so it isn't lost when the feature lands.
