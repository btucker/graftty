# zmx render desync — conditional silent gate

**Date:** 2026-06-10
**Status:** Approved
**Branch:** zmx-render-regression

## Problem

Since PR #201 (2026-05-26), zmx pane output frequently renders jumbled: the
cursor draws in the wrong place (usually too high), and new output overwrites
scrollback incorrectly. Resizing the window recovers the pane; typing in it
does not.

### Root cause

Two sources of truth for terminal size are allowed to diverge:

- **libghostty's grid** always follows the AppKit view.
  `SurfaceNSView.setFrameSize` (`Sources/Graftty/Terminal/SurfaceHandle.swift:620`)
  unconditionally calls `ghostty_surface_set_size`.
- **The zmx PTY winsize** is gated by IOS-12.1. `HostManagedZmxBackend`
  (`Sources/Graftty/Terminal/HostManagedZmxBackend.swift:303`) records but
  does not forward libghostty viewport callbacks while `attachState ==
  .silent`. The gate opens only on the first user keystroke in the pane.

zmx formats every byte it emits — line wrapping, absolute cursor-positioning
escapes — assuming the PTY winsize it was told. While the gate is closed and
the grid differs from the PTY winsize, every rendered byte is laid out for
the wrong grid. Panes the user watches without typing (agent output) stay
desynced indefinitely. The misformatted bytes also land in scrollback
history, so the damage is partly permanent.

Typing fails to recover the pane because `markUserInput()`
(`HostManagedZmxBackend.swift:339`) flushes only `lastSilentResize`, which is
nil when no viewport callback fired after attach (e.g. the cached
`initialGridSize` already matched layout), and nothing forces a repaint after
the flush. A window resize is the only path that guarantees changed dims →
SIGWINCH → zmx full repaint — hence the workaround.

### Why IOS-12.1 exists

When an iPhone/iPad client is attached to the same zmx session, the Mac
re-attaching must not resize the shared PTY out from under the mobile
size-leader (IOS-6.5/IOS-6.10/IOS-5.6). The gate is the Mac voluntarily
withholding resizes, mirroring the mobile client's own withhold-until-engaged
behavior. PR #201's commit message also cites "post-reattach width drift
caused by libghostty's pre-layout viewport callback shrinking the PTY" — a
Mac-only problem the gate happened to paper over.

Remote clients attach via separate `zmx attach` child processes:
`WebSession` (`Sources/GrafttyKit/Web/WebSession.swift`, WebSocket path) and
`TerminalSessionHandler`
(`Sources/GrafttyHostAgent/SSH/Channels/TerminalSessionHandler.swift`,
SSH-over-WebRTC path). Both run in the Graftty app process
(`GrafttyHostAgent` is a library; `GrafttyApp.swift:4` imports it). Today
there is no registry of attached remote clients.

## Design

**Invariant restored:** whenever no remote client is attached to a pane's zmx
session, the zmx PTY winsize equals libghostty's grid size once layout has
settled. Desync becomes structurally impossible in the single-device case and
recoverable in the multi-device case.

### 1. `RemoteAttachmentRegistry` (new, GrafttyKit)

Thread-safe class maintaining a per-session attach count:

- `attach(sessionName:)` / `detach(sessionName:)`
- `isRemoteAttached(sessionName:) -> Bool`
- `onLastDetach` observer: fires when a session's count drops to zero, so
  backends can sync immediately when the last mobile client leaves.

One shared instance owned by the app and injected — no global singleton, so
tests construct their own. Producers:

- `WebSession`: attach on successful `zmx attach` spawn, detach on close.
- `TerminalSessionHandler`: same, around its stream lifecycle.

Detach must be idempotent (close paths can run more than once).

### 2. `HostManagedZmxBackend` changes

`AttachState` stays; how it's consulted changes:

- **`receiveResize` while `.silent`:** forward to the PTY immediately
  **unless** `hasRemoteClient()` returns true. Forwarding does not flip
  engagement — engagement still flips only on user input. When gated (remote
  attached), record `lastSilentResize` as today.
- **Engagement flush (`markUserInput`):** query the surface's current grid
  size and flush that (not the possibly-nil `lastSilentResize`), then request
  `ghostty_surface_refresh`. Injected as closures from `SurfaceHandle`
  (`currentGridSize: () -> (cols: UInt16, rows: UInt16)?`, `requestRefresh:
  () -> Void`) so the backend stays free of libghostty calls and
  unit-testable. `SurfaceHandle` already has `queryGridSize()` and
  `refresh()`.
- **Last-remote-detach:** when the registry reports the session's last remote
  client detached and the backend is still `.silent`, perform the same
  sync-to-current-grid + refresh.
- **Pre-layout guard (preserves the original #201 fix):** ignore resize
  callbacks with zero dims or arriving before the view has a nonzero frame;
  once the first real layout lands, run a one-shot explicit PTY ← grid sync.
  "Wait for real layout" replaces "wait for user input" as the protection
  against libghostty's bogus pre-layout viewport callback.

### 3. Spec changes

- **IOS-12.1** EARS text becomes conditional: "While a remote client is
  attached to the pane's zmx session, a fresh attach with a libghostty
  viewport callback but no user input shall not resize the zmx PTY."
- New TERM-x.y specs (numbered to extend the existing terminal section):
  - No-remote forwarding: while no remote client is attached, a silent-state
    viewport callback shall resize the zmx PTY immediately.
  - Engagement flush: when the silent gate disengages, the application shall
    resize the PTY to the surface's current grid size and force a surface
    refresh.
  - Last-remote-detach sync: when the last remote client detaches from a
    session whose Mac pane is still silent, the application shall sync the
    PTY to the current grid size.
  - Registry semantics: attach/detach counting, idempotent detach,
    last-detach observer.

Each lands as a `@Test` title per project convention (RED → GREEN), and
`scripts/generate-specs.py` regenerates `SPECS.md`.

### 4. Testing

- `HostManagedZmxBackend` already injects `sessionFactory`; a fake session
  records resize calls. Drive `receiveResize` / `write` / detach callback and
  assert exactly when the PTY sees dims.
- **Reproduction test (RED first):** silent backend, no remote attached,
  viewport callback → assert the PTY is resized immediately. Fails on
  current code.
- Gated path: remote attached → callback recorded, not forwarded; first
  engaged write flushes current grid size and requests refresh.
- Registry suite: counting, idempotent detach, observer fires only on last
  detach.
- Wiring tests for `WebSession` / `TerminalSessionHandler` registry calls
  where existing test seams allow.

## Out of scope

- Mac rendering while gated (remote attached, user hasn't typed): the Mac
  still renders mismatched during that window, as today. Fixing it would
  require Mac-side letterbox/font-fit; the flush fix guarantees recovery on
  first keystroke instead of requiring a window resize.
- zmx binary changes (it's vendored, binary-only).
- Mobile-side leadership protocol changes — leadership remains the existing
  honor system.
