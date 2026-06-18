# Pane-size reconcile: collapse the TERM-11.x render-desync band-aids

**Date:** 2026-06-17
**Status:** Approved (design); supersedes the patch-by-patch approach in
`2026-06-10-zmx-render-desync-design.md`.
**Area:** `Sources/Graftty/Terminal/HostManagedZmxBackend.swift` (the size
state machine), `SurfaceHandle.swift` (size origin + show/visible wiring),
`TerminalManager.swift` / `MainWindow.swift` (lifecycle triggers).

## Problem

The sidebar pane renders vertically misaligned ("off by N lines",
interleaved frames) until the user manually resizes the window, which heals
it. Over ~14 `TERM-11.x` requirements the same failure has been patched once
per lifecycle event (attach, re-attach, layout-settle, engage, remote-detach,
occlude/re-show, focus-switch, worktree-switch, divider-drag). Each patch
added its own gate or its own reconcile; two of them (`TERM-11.11`,
`TERM-11.14`) **synthesize a fake resize** (`rows → rows-1 → rows`) to force a
repaint, and that hack needed its *own* timing band-aids (150 ms / 250 ms
legs). Recurring patches for one failure = an architecture problem.

## Root cause

zmx is **raw PTY passthrough with a single per-session grid.** The daemon
keeps one `ghostty_vt` terminal per session, sized to the **leader** client's
winsize, and broadcasts the child's PTY bytes *verbatim* to every attached
client — no per-client rendering, no dirty-diffing (verified in
`neurosnap/zmx` `src/main.zig`: `handleOutput`, `handleResize`, `setLeader`).

So the Mac's libghostty surface and the daemon's grid are **two independent
emulators parsing the same byte stream.** They render identically **iff their
row/col counts match.** The desync is exactly: **Mac visible grid ≠ daemon
(leader) grid** → passthrough bytes laid out for N rows get painted into an
M-row grid.

The whole bug therefore reduces to one invariant:

> **While a pane is visible (and the Mac is the session's leader), the daemon
> grid must equal the Mac's libghostty grid.**

Today that sync is **lossy**: it is driven by libghostty's *delta-only*
viewport callback (`receiveResize`) and then filtered through a gauntlet of
withhold/defer/coalesce gates (`shouldWithholdResizeLocked`, the
`silent`/`engaged` `AttachState` machine, `layoutSettled`). When a grid change
is dropped (occluded surface emits no delta; a gate withholds it) the daemon
falls behind and the panes diverge. The fake rows-bounce exists only to paper
over states the lossy sync reached where it *thought* the sizes agreed.

### Two stranding categories

- **A — Mac grid ≠ daemon grid.** The dominant case and the user's bug. A real
  size sync fixes it: forwarding the live grid is a *different* size → real
  `TIOCSWINSZ` → SIGWINCH → the child re-emits at the new size → both emulators
  render it identically.
- **B — equal size, app frame stranded.** The child's last-emitted frame is
  anchored wrong and baked into the daemon's screen while the sizes already
  agree. A same-size resize is a kernel no-op (no SIGWINCH); **detach+reattach
  does not fix it either** (zmx's `handleInit` replays the *current* — stranded
  — screen). Only forcing the child to re-emit (a SIGWINCH) repaints it.

B can only arise **after** an A violation baked a bad frame. Eliminate A and B
cannot occur. The fake bounce was compensating for A's lossiness, not for an
independent defect.

## Design

### 1. One authoritative reconcile (the core)

Replace the delta-driven + N-bespoke-reconciler model with a single method on
`HostManagedZmxBackend`:

```
reconcileSizeLocked(reason:)   // the ONLY path that sizes the PTY
```

It, under `lock`:
1. reads the **live** libghostty grid via the bound `currentGridSize` (the
   single source of truth — not a remembered delta);
2. applies **one** withhold predicate (see §3);
3. if the live grid differs from `lastForwardedResize`, forwards it
   (`session.resize`) and requests a refresh; if it already matches, no-op.

Every lifecycle trigger funnels here instead of carrying its own logic:
`markLayoutSettled`, first `markUserInput` (engagement), `remoteClientsDidDetach`,
the show/visible path (focus, `onAppear`, app-foreground, **and**
worktree-switch — all of them, not just worktree-switch), and the
divider/window resize callback (via the coalescer, §4). The receive-callback
becomes a thin "grid changed → reconcile" notifier rather than an independent
forwarder.

**Drives the sync from the real size, not the lossy delta.** Crucially the
show path calls `reconcileSizeLocked` which *queries* the live grid, so an
occluded-then-shown surface that libghostty never re-reported (no delta) is
still reconciled. This subsumes today's `resyncVisibleGrid` (TERM-11.13) and
generalizes it to every show trigger.

### 2. Delete the fake-resize re-anchor

Remove entirely: `healAnchorOnAttach`, `setAnchorHealOnAttach`,
`performAnchorHealLocked`, `scheduleAnchorHealBounceLocked`, `anchorHealShrink`,
`anchorHealRestore`, `reanchorOnShow`, `anchorHealShrinkDelay`,
`anchorHealRestoreDelay`, and the `SurfaceHandle`/`MainWindow`/`TerminalManager`
wiring that drives `reanchorOnShow` / `setAnchorHealOnAttach`. With the
authoritative invariant, category-A stranding cannot occur, so no fake SIGWINCH
is needed. **Phase 1 carries no recovery primitive** — it trusts the invariant.

### 3. Keep the legitimate constraints

These are real and survive (possibly simplified, not deleted):

- **Pre-layout withhold + deferred attach** (`layoutSettled`, the deferred
  `start` in `SurfaceHandle`): libghostty's pre-layout placeholder grid (49×17)
  must never reach the PTY, and attach must spawn at the settled grid. KEEP.
- **Remote-leader constraint** (the multi-client case): zmx's single-grid model
  cannot satisfy two differently-sized clients — the session renders at the
  leader's size. The Mac must not steal the size from a session a remote client
  is driving until the local user actually engages. KEEP as the *one* remaining
  withhold condition: `withhold = !layoutSettled || (notEngaged && hasRemoteClient)`.
  The `AttachState` silent/engaged flag and the opt-in engagement scopes
  (`withUserInputScope` / `emittedBytesClaimEngagement`, TERM-11.8) are retained
  for this purpose only — they decide when the Mac claims leadership. This is the
  one inherent zmx limitation; documented, not band-aided.
- **Coalescing** (TERM-11.9): a divider drag emits a viewport callback per
  frame; the 75 ms quiet window bounds the SIGWINCH stream. KEEP as a thin
  front-end whose trailing edge calls `reconcileSizeLocked`.
- **Pre-start write queue** (TERM-11.12) and **RemoteAttachmentRegistry**
  (TERM-11.5): KEEP unchanged.

### 4. Recovery for category B — deferred, and zmx-side when needed

If real-world testing surfaces a residual category-B strand (equal size, app
frame baked wrong), the correct fix is a **trivial zmx addition**: a `redraw
<session>` command that does `posix.kill(child_pid, SIG.WINCH)` — forcing the
child to re-emit a fresh frame with **no size change and no fake wiggle**. The
daemon already sends this signal on output (`handleOutput`); a new command
reuses the existing CLI dispatch + the child pid. This is **out of scope for
Phase 1** (we own zmx, so it's a cheap escape hatch, but we ship the invariant
first and only add it if B is actually observed). Explicitly **not**
detach+reattach (replays the stranded screen) and **not** the fake bounce.

## @spec changes

- **Delete:** `TERM-11.11`, `TERM-11.14` (the fake rows-bounce) — tests and
  the doc-comment specs. Remove the heal/bounce machinery they cover.
- **Reword / consolidate:** `TERM-11.1`, `TERM-11.3`, `TERM-11.6`, `TERM-11.13`
  collapse into a single new requirement describing the authoritative reconcile
  contract ("every visibility/lifecycle transition reconciles the PTY to the
  *live* grid; an occluded-then-shown surface is reconciled by querying the grid,
  not by waiting for a libghostty delta").
- **Keep unchanged:** `TERM-11.2`, `TERM-11.4`, `TERM-11.5`, `TERM-11.7`,
  `TERM-11.8`, `TERM-11.9`, `TERM-11.10`, `TERM-11.12`.
- **Add:** one new `TERM-11.x` spec for the single-reconcile invariant.

Regenerate `SPECS.md`.

## Components & data flow

```
NSView.setFrameSize ──► ghostty_surface_set_size ──► (libghostty grid)
        │                                                   │
        │ (queryGridSize)                                   │ receive_resize cb
        ▼                                                   ▼
  show/visible / settle / engage / remote-detach ──► reconcileSizeLocked(reason:)
                                                            │  one withhold predicate
                                                            │  forward iff grid != lastForwarded
                                                            ▼
                                                   session.resize ─► TIOCSWINSZ ─► SIGWINCH
                                                            ▼
                                              zmx daemon: term.resize + child re-emits
                                                            ▼
                                              raw bytes broadcast ─► Mac libghostty renders
```

Divider/window drags route the callback through the existing coalescer; its
leading edge and trailing edge both end in `reconcileSizeLocked`.

## Testing strategy

Unit-testable at the `HostManagedZmxBackend` seam (existing
`HostManagedZmxBackendTests` / `SurfaceHandleHostManagedTests` use a fake
`HostManagedZmxSession` recording `resize` calls and an injected
`currentGridSize`). RED/GREEN per the project TDD process:

1. **Invariant on show.** A running backend whose injected grid drifts while
   "occluded" (grid provider returns a new size, no `receiveResize` delta) must,
   on the show trigger, forward the *live* grid exactly once. (Replaces the
   TERM-11.13 test, generalized to all show triggers.)
2. **No fake bounce.** After a show/attach at a grid that already matches
   `lastForwardedResize`, the backend forwards **zero** resizes (the bounce is
   gone). Asserts the rows-1/rows pair never appears.
3. **Single forward on real drift.** Grid 80×24 → 80×30 on show forwards exactly
   one 80×30 resize (the real SIGWINCH), not a bounce.
4. **Remote-leader constraint preserved.** While `hasRemoteClient` is true and
   the pane is not engaged, a show/settle does **not** forward; first user input
   (engagement) then forwards once. (Keeps TERM-11.2/11.4/11.8.)
5. **Pre-layout withhold preserved.** Before `markLayoutSettled`, no forward
   regardless of trigger (TERM-11.7).
6. **Coalescing preserved.** A drag storm forwards leading-edge immediately and
   one trailing size per window (TERM-11.9).

**Verification limitation (state explicitly):** the actual *visual* desync can
only be confirmed by running the app against live terminals, which cannot be
done headlessly or against the user's live zmx sessions. Unit tests pin the
backend's forward/withhold decisions; final visual confirmation is the user's
manual check after the PR builds.

## Out of scope

- The zmx `redraw`/SIGWINCH command (category-B escape hatch) — separate, only
  if observed.
- Per-client rendering in zmx (the only true fix for the multi-size remote
  case) — a large zmx change, not pursued.
- Any change to the web/`WebSession` PTY path.

## Risks

- **Subtle subsystem, heavily patched.** Mitigation: keep every legitimate
  constraint and its test; only delete the fake-bounce and collapse the
  reconcilers; TDD each behavior.
- **Can't verify visually in CI.** Mitigation: comprehensive backend unit
  tests + explicit user manual-verify step before merge.
- **Category B regression.** If the invariant has a hole we missed, B could
  recur. Mitigation: the deferred zmx-SIGWINCH escape hatch is a ~10-line
  follow-up, not a rewrite.
