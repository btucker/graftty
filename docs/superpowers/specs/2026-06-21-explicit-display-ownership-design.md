# Explicit display ownership for shared terminal sessions

**Date:** 2026-06-21
**Status:** Draft design
**Area:** zmx-backed native panes, web/iOS terminal bridges, GrafttyMobile terminal sizing

## Problem

Graftty currently treats "shared zmx session" as an implicit behavior rather
than an explicit contract. A session can have a Mac pane, web/iOS clients, and
preview renderers attached at the same time, but the product does not clearly
say who owns the PTY size or who is allowed to send input.

The implementation therefore infers ownership from incidental events:

- Mac panes withhold or forward resizes based on `isRemoteAttached`,
  `layoutSettled`, `AttachState.silent`, first user input, visibility, and
  re-show reconciliation.
- iOS can claim size leadership from first keystroke, pinch, or long press.
- Followers still run real terminal views whose local viewport may disagree
  with the daemon grid.

That hidden policy is the source of the repeated vertical sizing bugs. zmx has
one daemon grid per session, while each client has its own local view size. If
more than one client behaves like a size leader, one resize path eventually
wins accidentally and another client renders bytes using the wrong grid.

## Product contract

Each session has zero or one **display owner** at a time.

Only the display owner may:

- send user input to the PTY;
- resize the PTY;
- define the session's authoritative `(cols, rows)`.

All non-owners are **followers**. Followers may receive output, render the
authoritative display grid, and press **Take Control**, but they may not send
input and may not resize the PTY.

Ownership changes are explicit. Any visible follower may press **Take Control**.
Takeover happens immediately. The new owner computes its natural local grid
from its current terminal content area and immediately resizes the PTY to that
grid. The previous owner becomes a follower.

Ownerless is an explicit state, not an implementation accident. It is allowed
when a session exists before any visible interactive client has attached, after
the owner disconnects, or after the owner releases its lease.

Allowed ownership transitions:

- `ownerless -> owned`: a visible interactive client claims ownership with an
  explicit `claimOwner` request and a natural local grid.
- `owned -> owned`: a visible follower presses **Take Control** and claims
  ownership with its natural local grid; the previous owner becomes a follower.
- `owned -> ownerless`: the owner disconnects or releases ownership.
- `ownerless -> ownerless`: followers attach, resize locally, or detach without
  claiming.

The only automatic claim happens on attach, and only when all of these are
true:

- the session is ownerless;
- the attaching client is interactive, not a preview;
- the attaching client is visible at attach time;
- the attach is a new client identity, not an existing follower re-rendering or
  resizing.

If an owner disconnects while followers remain, the session becomes ownerless.
Existing followers stay read-only and show **Take Control** rather than
silently promoting one follower and changing the PTY size.

## Follower rendering contract

Followers render the authoritative display grid; they do not create their own
grid.

When the session is owned, the authoritative display grid is the owner's most
recent accepted grid. When the session is ownerless, the authoritative display
grid is the last accepted owner grid for that session. If the session has never
had an accepted owner grid, clients render the current daemon-reported grid as
a read-only ownerless view until an interactive client claims ownership.

Preview tiles are always followers and never show takeover UI. In ownerless
sessions they use the same authoritative display grid rule: last accepted owner
grid if present, otherwise the daemon-reported grid.

Follower fit policy:

- preserve the owner `(cols, rows)`;
- compute font/cell size from available width so `ownerCols` fits the local
  width;
- do not resize the PTY to fit height;
- if the rendered owner rows are shorter than the local terminal content
  height, letterbox vertically;
- if the rendered owner rows exceed the local terminal content height, clip or
  scroll the follower view;
- block all PTY-bound input and show a **Take Control** affordance.

This intentionally makes vertical mismatch a presentation issue rather than a
session-size issue.

## Mobile viewport contract

GrafttyMobile must compute owner grids and follower fit using the actual
terminal content rectangle, not the full SwiftUI container.

Today `RootView` applies `keyboardBottomInset` as bottom padding so the whole
session view rides above the software keyboard, then overlays
`terminalChrome` at the bottom. The terminal `GeometryReader` still sees the
full post-keyboard container, so an owner can compute rows into space later
covered by the Graftty control bar/accessory row. The result is a shell bottom
line hidden behind the control bar.

New invariant:

```
terminalViewportHeight = containerHeight - visibleTerminalChromeHeight
```

The owner grid uses `terminalViewportHeight`. Follower width-fit still uses
width, but vertical letterbox/clip uses `terminalViewportHeight`. Bottom chrome
is reserved layout space, not terminal content.

The control bar height should be measured through a SwiftUI layout preference
or an equivalent chrome-height helper. Do not hardcode a guessed row height.
The rule applies whenever bottom terminal chrome is visible, including the
normal software-keyboard control bar and the compact "Show keyboard" affordance.

## Architecture

Introduce a `SessionDisplayOwnershipStore` keyed by zmx session name.

Each record contains:

- `sessionName`;
- `ownerClientID?`;
- `ownerKind?` (`mac`, `web`, `ios`);
- `grid`: the last accepted authoritative display grid;
- `epoch`.

The epoch increments on every ownership change. Resize/input paths include the
client identity and only succeed when the caller matches the current owner and
epoch. This prevents stale async resize callbacks from a prior owner landing
after takeover.

Client identity is per attachment, not per app or saved session:

- Mac panes create a new `clientID` for each `HostManagedZmxBackend`
  attachment. Hide/show, visibility changes, and surface recreation keep the
  same client identity while the backend attachment lives. Closing the pane or
  tearing down the backend releases that identity. Reopening creates a new
  identity.
- Web and iOS bridge clients create a new `clientID` for each websocket
  connection. Reconnecting creates a new identity even if it represents the
  same device or app session.
- Preview tiles create a new preview identity per preview attachment and are
  never eligible to own.

A disconnected identity cannot retain ownership. If the current owner identity
disconnects, the store moves to ownerless, preserves the last accepted grid,
increments `epoch`, and broadcasts the ownerless snapshot.

Core operations:

```
attachClient(sessionName, clientID, kind, role, visible, autoClaimIfEligible)
  -> OwnershipSnapshot
claimOwner(sessionName, clientID, ownerKind, grid) -> OwnershipSnapshot
ownerResize(sessionName, clientID, epoch, grid) -> accepted/rejected
releaseOwner(sessionName, clientID, epoch)
currentSnapshot(sessionName) -> OwnershipSnapshot
```

Ownership snapshots are broadcast to attached clients so every client knows
whether it is owner, follower, or ownerless.

## Data flow

### Owner resize

```
owner local layout
  -> compute natural local grid from terminal content rectangle
  -> ownerResize(session, ownerClientID, epoch, grid)
  -> accepted by ownership store
  -> zmx attach PTY resize
  -> zmx daemon resizes child PTY
  -> server broadcasts grid/ownership snapshot
  -> followers fit authoritative display grid locally
```

### Follower resize

```
follower local layout
  -> compute width-fit font for current authoritative display grid
  -> no PTY resize
  -> no ownership mutation
```

### Take control

```
follower presses Take Control
  -> compute natural local grid from terminal content rectangle
  -> claimOwner(session, followerClientID, kind, grid)
  -> epoch increments
  -> PTY immediately resizes to new owner's grid
  -> old owner receives follower snapshot and stops input/resize authority
```

## Component impact

### Mac native panes

`HostManagedZmxBackend` should stop encoding implicit ownership with
`AttachState.silent`, `hasRemoteClient`, and show-time resize stealing. It
should ask the ownership store whether this Mac pane owns the session.

- Owner Mac panes forward local grid changes and user input.
- Follower Mac panes block PTY-bound input, suppress PTY resizes, and render
  using authoritative-grid follower fit.
- `TerminalManager.setVisible(true)` may refresh and reconcile presentation,
  but it must not claim ownership or resize the PTY unless this client is the
  owner.

### Web and iOS

`WebControlEnvelope.resize` and input frames should be accepted only from the
current owner. Follower clients receive output and ownership/grid snapshots but
do not resize or write.

The current iOS `isSizeLeader` model becomes ownership state. First keystroke,
pinch, and long-press should no longer implicitly claim leadership. They should
be replaced by a visible **Take Control** action. If iOS is already owner, input
and layout-driven resize continue normally.

### Preview tiles

Preview tiles are followers with no takeover UI. They render the authoritative
display grid using width-fit font sizing and never send input or resize.

## Deleted or collapsed concepts

This design is intended to remove these implicit policies:

- `RemoteAttachmentRegistry.isRemoteAttached` as a resize gate;
- Mac `AttachState.silent` / first-input engagement as hidden size leadership;
- iOS `isSizeLeader` as a local-only flag independent of session ownership;
- resize authority inferred from focus, visibility, worktree switch, or
  `onAppear`;
- follower resize frames;
- show-time "take back" resize reconciliation when the visible pane is not
  owner.

`RemoteAttachmentRegistry` may still exist as connection accounting, but it
must not decide resize authority.

## Testing strategy

Unit-test the ownership store independently:

- first visible interactive attach auto-claims when ownerless;
- existing followers do not auto-claim after owner disconnect;
- follower **Take Control** increments epoch and replaces owner;
- owner resize accepted only for matching owner and epoch;
- stale resize from old epoch rejected after takeover;
- owner release makes the session ownerless without silently promoting an
  existing follower.

Backend/bridge tests:

- Mac owner forwards resize and user input;
- Mac follower suppresses resize and blocks input;
- web/iOS owner resize accepted;
- web/iOS follower resize rejected;
- takeover immediately sends the new owner grid to the PTY;
- old owner becomes follower and stops forwarding resize/input.

Mobile layout tests:

- terminal content height subtracts measured bottom chrome height;
- owner grid calculation uses reduced content height;
- follower vertical letterbox/clip uses reduced content height;
- keyboard control bar and compact show-keyboard chrome both reserve height.

Integration/manual verification:

- Mac owns, iOS follows: iOS width-fits Mac grid and cannot type.
- iOS takes control: PTY immediately resizes to iOS content area; Mac becomes
  read-only follower.
- Keyboard opens on iOS while iOS owns: bottom shell row remains visible above
  the control bar.
- Mac takes control back: iOS becomes follower and stops sending input/resize.

## Risks and tradeoffs

- This changes product semantics from "every attached client can interact" to
  "one owner, many followers." That is intentional, but the UI must make it
  obvious.
- Width-primary follower rendering can be awkward on very small devices when
  the owner grid is large. This is acceptable for read-only following; takeover
  is the escape hatch.
- Existing tests and specs around `IOS-6.5`, `IOS-6.10`, `TERM-11.x`, and
  `RemoteAttachmentRegistry` will need rewording rather than another layer of
  exceptions.
- zmx still has one daemon grid. The design embraces that limitation instead
  of trying to hide it.

## Out of scope

- Per-client terminal emulators in zmx.
- Concurrent multi-client editing/control.
- Collaborative cursors or multi-user input arbitration.
- Changing session survival semantics.
