# iPad render throttle — design

**Date:** 2026-07-10
**Status:** approved
**Problem:** iPad battery drains noticeably during active use of the app.

## Root cause

The terminal render loop has no brake at either end. libghostty-spm's
`TerminalSurfaceCoordinator.tick()` calls `ghostty_app_tick` +
`surface.refresh()` + `surface.draw()` on every display-link fire with no
dirty check, and MSDisplayLink's single shared `CADisplayLink` never sets
`preferredFrameRateRange`, so ProMotion iPads run the full Metal pipeline
at up to 120 Hz. The app's existing idle machinery (snapshot swap) covers
sidebar previews (10 s threshold) but is disabled for the focused
terminal: `fullscreenIdleThreshold = .infinity`
(`SessionLifecycleEnvironment.swift`), and the idle watchdog early-returns
on a non-finite threshold (`SessionClient.swift`). Net effect: a visible,
quiet terminal renders at native refresh rate indefinitely.

Secondary findings deliberately **out of scope** for this round (fix
later if drain persists): unbounded live pane previews
(`maxLivePreviews = .max`), WebRTC peer connections accumulating across
host switches (`RemoteConnectionCoordinator.invalidate(host:)` has no
call site) with `continualGatheringPolicy = .gatherContinually`, and
`.inactive` scene phase keeping connections alive.

## Decision

Per-surface render-pace throttling: a quiet terminal draws at ~1 fps
instead of native rate, with instant promotion back to full rate on
activity. No visual transition, no snapshot machinery, no unmount. Chosen
over pausing entirely (0 fps risks a permanently stale screen if a
promotion signal is ever missed — 1 fps is the safety net) and over a
global frame-rate governor (too coarse: one busy pane would keep every
surface at full rate). Active rendering keeps the display's native rate
(no 60 Hz cap).

## Fork change (btucker/libghostty-spm, branch `expose-selection-api`)

New public API on `UITerminalView`, forwarded to its
`TerminalSurfaceCoordinator`:

```swift
public enum TerminalRenderPace: Equatable {
    case full                              // draw every tick (default)
    case reduced(interval: TimeInterval)   // full tick at most once per interval
}
```

`tick()` gates its **entire body** — including `ghostty_app_tick` — on
the pace: while `.reduced(interval)`, the body runs only when
`now - lastTickTimestamp >= interval`. Rationale for throttling
`ghostty_app_tick` too: fewer CPU wakeups; anything that needs prompt
libghostty attention (output, input) also fires an app-side promotion to
`.full`, so callback latency of up to 1 s applies only while genuinely
quiet.

Edge cases:

- `synchronizeMetrics()` (resize, rotation, scale change) resets the
  throttle timestamp so the next tick draws immediately — no stale-sized
  frame for up to a second after rotation.
- Setting `renderPace = .full` needs no special casing; the next
  display-link fire draws naturally.
- The shared `CADisplayLink` is untouched; a throttled surface's tick
  costs one timestamp comparison.

Delivery: commit on the existing `expose-selection-api` fork branch, then
`swift package update libghostty-spm` in graftty to bump
`Package.resolved`.

## App change (GrafttyMobileKit)

**Governor.** `SessionClient` gains a published
`renderPace: TerminalRenderPace` (default `.full`) alongside
`renderActivity`, using the idle-watchdog pattern: every activity signal
stamps `lastActivityAt`, promotes to `.full` if reduced, and (re)arms a
demotion task that fires after the quiet delay, setting
`.reduced(interval: 1.0)`.

**Constants** (in `SessionLifecycleEnvironment` beside
`previewIdleThreshold`): quiet delay **5 s**, reduced interval **1 s**.

**Promotion signals** (each restores full pace immediately):

1. **Output** — the WS receive loop already calls `recordActivity()` per
   frame; the governor hooks the same call.
2. **Keyboard/paste input** — `sendSoftwareKeyboardText`,
   `deleteBackward`, `sendPaste`, and the hardware-key path all route
   through `SessionClient` sends; one hook covers them.
3. **Touch on the terminal** — scrolling/pinch render locally with no
   host output. `TerminalInputContainerView` gets an `onUserInteraction`
   callback fired from a non-cancelling, simultaneous any-touch-began
   recognizer; `RootView` wires it to the governor.

**Flow:** `SessionClient.renderPace` → `TerminalPaneView` (new
parameter, applied in `updateUIView`) → `UITerminalView.renderPace`.

**Interactions:** previews keep their 10 s snapshot-unmount (they gain
throttling for the 5–10 s window — strictly cheaper); fullscreen keeps
never-unmounting but spends quiet time at ~1 Hz; background/`.inactive`
teardown paths unchanged.

## Specs (EARS, render-lifecycle section)

- While a terminal session has received no output or user interaction
  for 5 seconds, the application shall reduce that surface's render pace
  to at most one frame per second.
- When output, input, or a touch arrives while a surface is
  render-reduced, the application shall restore full render pace
  immediately.

## Testing

- App-side governor unit tests: promote/demote/re-arm timing, each of
  the three signal paths, default-full initial state.
- Fork-side: small coordinator test for tick gating if the spm package
  harness allows; otherwise covered end-to-end by app tests.
- Manual energy verification: Xcode energy gauge / Instruments
  before-vs-after with a quiet terminal on screen; expect GPU frame rate
  to drop to ~1 fps after 5 s.

## Success criteria

A foreground iPad with a quiet terminal visible drops from continuous
native-rate rendering to ~1 fps within 5 s, with no user-visible
transition, and typing/output/scroll feel indistinguishable from today.
