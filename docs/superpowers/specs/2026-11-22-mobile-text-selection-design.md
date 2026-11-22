# Mobile text selection and link menu

Approved by the user on 2026-11-22.

## Intent

Selecting terminal text in GrafttyMobile should feel like selecting text
anywhere else on iOS. Today, long-press → Select leaves a highlight with no
handles, and every one-finger drag then extends the selection, so the user
cannot scroll. Separately, long-pressing a link should open it on the phone
by default; opening it on the remote host stays available as a second option.

## Goals

- Long-press selects the word under the finger and shows start and end
  handles and an edit menu (Copy, Select All, Paste).
- Double-tap selects a word; triple-tap selects a line.
- Dragging a handle adjusts that end, with the loupe and edge autoscroll.
- One finger always scrolls. A selection stays put while the user scrolls.
  Only handle drags change it.
- Tapping elsewhere dismisses the selection.
- Long-pressing an HTTP(S) link offers **Open Link** (this device, default
  browser), **Open on ⟨host name⟩** (the originating pane browser, today's
  behaviour), and **Copy Link**, alongside the text actions.

## Non-goals

- Mac behaviour. This is GrafttyMobile only.
- An in-app browser sheet for local links.
- Changing iPad pointer (trackpad/mouse) selection.

## Anti-goals

- A selection that blocks scrolling.
- Synthesized mouse events for touch selection (they break in
  mouse-capturing TUIs and can only move one end).

## Approaches

1. **Use the in-repo terminal library's inline touch selection (picked).**
   `Sources/GhosttyTerminal` already implements handles, loupe, double and
   triple tap, and autoscroll (`UITerminalView+TouchSelection*.swift`,
   `TerminalTouchSelectionOverlay`). Graftty disables it by conforming
   `TerminalInputContainerView` to `TerminalSurfaceTextSelectionRequestDelegate`.
   Remove that conformance and Graftty's `TerminalSelectionController`
   mode; supply menus through the `touchMenuItems(for:)` and
   `touchSelectionMenuItems(for:)` overrides on `MobileTerminalInputView`.
2. **Keep Graftty's mouse-faking selection and draw handles over it.**
   Rejected: faked clicks hold one anchor, cannot move the start, and
   misbehave when a TUI captures the mouse.

## Decisions (user)

- Long-press selects the word immediately; there is no intermediate
  "Select" item.
- "Locally" means the phone's default browser via `UIApplication.open`.

## Left to the builder

- Library change: while a selection exists, a one-finger pan scrolls instead
  of extending (`handleTouchScrollGesture`, `panUsesSelection`), and the
  two-finger-only local scroll rule goes with it. A scroll must not dismiss
  the selection; the overlay follows the viewport offset.
- Long-press in the library opens a menu without selecting; make it select
  the word (as double-tap does) and present the selection menu. On blank
  space with nothing nearby, fall back to the no-selection menu (Paste,
  Select All).
- Link detection must keep working without the host request: IOS-11.23 to
  11.26 rely on the Cmd-hover probe in `presentLongPressMenu`. Move that
  probe to the menu-building path, keeping its guards (no mouse capture,
  stale-session discard).
- Checkpoint canvas (`TerminalSnapshotScrollView`, TERM-12.13): the overlay
  is a subview of the terminal view, so it scales with the canvas; verify
  handle hit targets and that the scroll view's pan stays live.
- Back swipe (IOS-4.44) and control-bar key cancel (IOS-11.7) currently read
  `selectionController.isActive`; point them at the library's selection
  state.
- Host name for "Open on ⟨host⟩" comes from the pane's host; fall back to
  "Open on Host".
- Specs: rewrite IOS-11.1 to 11.7 and 11.13 to the new behaviour; remove
  specs for deleted behaviour; regenerate `SPECS.md`. No literal quotes in
  spec titles.
- Tests first. macOS `swift test` does not compile UIKit-guarded code, so
  confirm with the iOS simulator build and iOS CI.
