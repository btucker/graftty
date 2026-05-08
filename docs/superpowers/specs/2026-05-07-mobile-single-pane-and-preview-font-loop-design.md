# Mobile: skip pane-tree for single-pane worktrees, and stop the preview font-size feedback loop

**Date:** 2026-05-07
**Status:** Approved

## Problem

Two issues in `GrafttyMobile`, related only by location:

### 1. The pane-tree screen is wasted real-estate when a worktree has one pane

Today the navigation flow is:

```
HostPicker → WorktreePicker → WorktreeDetail (pane tree) → SingleSession (fullscreen)
```

`WorktreeDetailView` (`Sources/GrafttyMobileKit/UI/WorktreeDetailView.swift`)
is built around faithfully mirroring the Mac sidebar's split tree
(`IOS-4.10`). That's the right call for split layouts. For a
single-leaf layout it's nothing but one labeled tile — the user has to
tap it once to reach the fullscreen terminal that they were going to
end up in anyway. (`IOS-4.14` already special-cases this case to skip
the live-preview WebSocket pool, which makes the wasted screen even
more obviously a no-op.)

### 2. Preview tile font-size grows monotonically across refreshes

`PaneTile.resizeController` in
`Sources/GrafttyMobileKit/UI/PaneLayoutView.swift` computes a font-size
from the tile's geometry and the server-announced column count
(`fontSize ≈ tileWidth / serverCols × 0.95 / 0.6`, see `IOS-4.12`). The
intent is "render the server's grid at scale 1 within the tile."

The implementation accidentally creates a feedback loop with the
server's PTY width:

1. Preview mounts. libghostty in the preview controller emits some
   internal bytes (terminal answerback / cursor query / etc.) — not
   user-typed.
2. `SessionClient.onBytes` (`Sources/GrafttyMobileKit/Session/SessionClient.swift:97`)
   forwards those bytes upstream and calls `claimLeadershipIfNeeded`.
   The preview client is now the size-leader.
3. libghostty's next `onResize` callback (which fires whenever font
   metrics or layout change) lands in `handleViewport`, which now
   takes the `if isLeader` branch and emits a `WebControlEnvelope.resize`
   to the server.
4. The server resizes the PTY, broadcasts a `.grid(cols, rows)` envelope
   back. The preview's `serverGrid.cols` updates.
5. `SizingKey` re-fires; a new font-size is computed against the new
   `cols`. Because libghostty's effective render width is slightly less
   than the SwiftUI `tileWidth` (chrome / clipping / overlay), each
   cycle yields a smaller `cols` and therefore a **larger** font-size —
   monotonically.

The bug exists because previews participate in size leadership at all.
They shouldn't — `IOS-6.5` reserves leadership for the focused
fullscreen pane, on the user's first keystroke.

## Change

### §1 — Direct push to fullscreen for single-leaf worktrees

When the user picks a worktree whose `layout?.isLeaf == true`, push a
`SessionStep` straight onto the navigation stack instead of a
`WorktreeStep`. The pane-tree screen is reached only for split layouts.
Edge-swipe-back and the in-app overlay back button (`IOS-5.5`) return
the user to the worktree picker, exactly as if the detail screen had
never existed.

The decision is a pure function of `(host, worktree)`. Extract it as a
small helper so the navigation push site stays tiny and the rule is
unit-testable without touching SwiftUI.

`WorktreeDetailView`'s existing `IOS-4.14` single-leaf carve-out (static
tile, no preview pool) is kept as defense-in-depth: if a multi-pane
worktree's panes are closed remotely down to one while the user is on
the detail screen, the static-tile fallback continues to be correct.

### §2 — Preview clients never claim PTY size-leadership

`SessionClient` gains a `Role` (`{ fullscreen, preview }`, default
`.fullscreen` for source compatibility). In `.preview`:

- The `onBytes` closure is a no-op. Bytes libghostty emits in the
  preview controller are discarded — they're internal answerback from a
  read-only thumbnail, not user input. `claimLeadershipIfNeeded` is
  never called.
- `handleViewport` short-circuits before the leadership branch. Even if
  some future code path were to set `isLeader`, the preview role would
  still refuse to emit a `resize` envelope.

`PanePreviewClientPool`'s factory passes `role: .preview` when
constructing previews; the fullscreen path
(`SingleSessionView.openWebSocket`) is unchanged.

The existing in-place `setTerminalConfiguration(fontSize:)` mutation in
`PaneTile.resizeController` is left as-is. With the upstream
feedback severed, `serverGrid.cols` is stable for the lifetime of a
session and the in-place update path runs at most once per legitimate
geometry change (rotation).

## Spec entries

- `IOS-4.17`: When the user selects a worktree from the picker
  (`IOS-4.1`) and that worktree's pane layout is a single leaf, the
  application shall push the fullscreen terminal for that pane directly
  onto the navigation stack, bypassing the worktree-detail screen
  (`IOS-4.10`). The system edge-swipe-back gesture and the in-app back
  button (`IOS-5.5`) shall return the user to the worktree picker.
- `IOS-4.18`: While a `SessionClient` is operating as a worktree-detail
  pane preview (`IOS-4.10`, `IOS-4.12`), the application shall not claim
  PTY size-leadership. Bytes emitted by libghostty in the preview
  controller shall be discarded rather than forwarded to the server,
  and layout-driven resize callbacks shall not produce
  `WebControlEnvelope.resize` frames. Size-leadership remains a property
  exclusive to the focused fullscreen pane (`IOS-6.5`).

## Tests

Per the global TDD rule, each behavior gets a failing test before its
implementation lands.

**`IOS-4.17` (single-leaf direct push):**
A pure helper, e.g. `MobileNavigationStep.next(host:worktree:)`, returns
either a `SessionStep` or a `WorktreeStep`. Tests cover the three
relevant layouts:
- single leaf → `.session(SessionStep)` carrying the leaf's `sessionName`
  and `displayTitle`.
- horizontal/vertical split → `.worktree(WorktreeStep)`.
- nil layout (no panes) → `.worktree(WorktreeStep)` (the worktree-detail
  screen owns the empty-state UI).

**`IOS-4.18` (no leadership claim from previews):**
A `SessionClient` constructed with `role: .preview` against an
in-memory `WebSocketClient` test double:
1. Drive the libghostty `box.onBytes` callback with non-empty `Data`
   (simulating internal answerback). Assert the test double observed
   **zero** `.binary(...)` frames upstream.
2. Call `handleViewport(_:)` with cols/rows > 0. Assert the test double
   observed **zero** `.text(...)` frames (no resize envelope).
3. Repeat steps 1–2 with the default `.fullscreen` role and assert
   leadership claim occurs as today (regression guard).

The existing `WorktreeDetailPreviewPolicyTests` (`IOS-4.14`) and
`PanePreviewFontSizingTests` (`IOS-4.12`) stay as-is.

## Out of scope

- Rebuilding the `TerminalController` on font-size change. Considered
  during brainstorming as a "structural cleanup" complement to §2;
  dropped because once the leadership feedback is severed, the in-place
  update path is well-behaved and the rebuild adds churn without a
  matching observable bug.
- Any changes to fullscreen leadership semantics (`IOS-6.5`).
