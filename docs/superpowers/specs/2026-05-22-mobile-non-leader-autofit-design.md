# Mobile Non-Leader Auto-Fit — Design

**Date:** 2026-05-22
**Branch:** `terminal-width`
**Scope:** iPhone fullscreen + iPad split-view leaves + PTY width persistence across detach

## Summary

When a GrafttyMobile client is not the size-leader, render the remote PTY at its server-announced column count by **shrinking the iOS-side font** to fit, never by wrapping the pane in a horizontal `ScrollView`. The pane always takes the full container width. Leadership is claimed on any deliberate input event (keystroke, pinch, long-press); a passive tap does not claim. The PTY's column count must not change while no client has claimed leadership since the last detach.

This replaces two existing specs — **IOS-5.6** (iPhone fullscreen scroll-view fallback) and **IPAD-2.5** (iPad split-view scroll-view fallback) — and extends the leadership-claim trigger set introduced in **IOS-6.5**.

## Motivation

Today, when iOS is connected to a session whose PTY is wider than the device can render at libghostty's configured font size, the pane is wrapped in a horizontal `ScrollView` (IOS-5.6 / IPAD-2.5). The user must scroll sideways to read past the screen's right edge.

This is the wrong default for a mobile read surface. The pane-preview path (IOS-4.12) already proves the right pattern: compute a font size from `containerWidth / serverCols` and let libghostty render the full grid at that scale. Apply the same pattern to the fullscreen / leaf pane and the user can always see every column at once.

Separately, the user has observed PTY width drift in a single-client scenario: the Mac app disconnects alone, reconnects alone, and the PTY's column count is smaller than it was before. This violates the broader invariant that width should be a property the user controls — never something that mutates silently in response to attach/detach events.

## Requirements (EARS)

### IOS-5.6 (updated)

While the iOS client is not the size-leader and the server-announced grid's column count exceeds what fits in the device's container at the configured (iOS-scaled) font size, the application shall override the terminal controller's font size so that `serverCols × cellWidth ≤ containerWidth`, render the pane at the full container width with no horizontal `ScrollView`, and never wrap a line.

### IPAD-2.5 (updated)

While an iPad pane-layout leaf is not the size-leader and the server-announced grid's column count exceeds the leaf's allotted width at the configured font size, the application shall apply the same font-fit policy as IOS-5.6 (per-leaf), rendering each leaf's pane at the full leaf width with no horizontal `ScrollView`.

### IOS-6.5 (updated — claim triggers extended)

The iOS client shall claim size-leadership on the first of these events within a session: (a) any keystroke, (b) any pinch-gesture begin on the terminal pane, (c) any long-press-gesture begin on the terminal pane. Subsequent libghostty-reported viewport changes shall be forwarded to the server. Before any of these events, layout-driven resize callbacks shall be memoized but not sent.

A tap shall not claim size-leadership.

### IOS-6.10 (new — freeze-on-claim)

When the iOS client claims size-leadership (per IOS-6.5), the font size currently applied to the terminal controller shall remain in effect as the new baseline — including any active auto-fit override from IOS-5.6 / IPAD-2.5. The application shall stop driving the font from `TerminalWidthLayout.decide` for that session from that point forward. libghostty's pinch-to-zoom (IOS-6.8) shall mutate font from this baseline.

### IOS-12.1 (new — PTY width persistence across detach)

While no client has claimed size-leadership since the last `zmx` session reached zero attached clients, the PTY's column count shall not change. A client connecting alone shall not implicitly resize the PTY; resize shall occur only on explicit leader-claim signals (per IOS-6.5 for iOS; the equivalent for the Mac client — see *Investigation*).

## Architecture

### Component changes

| File | Change |
|---|---|
| `Sources/GrafttyMobileKit/Terminal/TerminalWidthLayout.swift` | Decision type changes from `.fits / .scrollable(frameWidth:)` to `.useConfigFont / .fitFont(pointSize:)`. `cellWidth` drops from inputs; `configFontSize` is added. `fallbackCellWidth` constant deleted. |
| `Sources/GrafttyMobileKit/App/RootView.swift` | `activeTerminal` no longer wraps in `ScrollView`. On `.fitFont`, applies the override via `controller.updateConfigSource(.generated(appendingFontSizeOverride(...)))`. On `.useConfigFont` while not-leader, restores base config. Once `isSizeLeader == true`, stops re-running the decision. |
| `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift` | `TerminalInputContainerView` adds: a sibling `UIPinchGestureRecognizer` (with `shouldRecognizeSimultaneouslyWith` permitting libghostty's recognizer to coexist) that calls `client.claimLeadershipIfNeeded()` on `.began`; a one-line addition to `handleLongPress(_:)` at `.began` to do the same. |
| `Sources/GrafttyMobileKit/Session/SessionClient.swift` | `claimLeadershipIfNeeded()` exposed publicly for gesture-driven calls. No new state — same code path the keystroke branch already uses. |
| `Sources/GrafttyMobileKit/Session/GhosttyConfigFetcher.swift` | Already exposes `lastFontSize(in:)`; `RootView` parses the iOS-scaled font size from the fetched config to pass as `configFontSize` to `decide`. No code change in this file unless extraction needs hardening. |
| `Sources/GrafttyMobileKit/UI/PaneLayoutView.swift` | iPad multi-pane leaves call the same `TerminalWidthLayout.decide` and apply the same font override. Removes the per-leaf `ScrollView` branch. |

`PanePreviewFontSizing` is **not** touched — pane-tile previews continue to use it directly. `TerminalWidthLayout` reuses its constants (`monospaceAspect`, `safetyScale`, `minimumFontSize`) so the math stays one source of truth — either by re-exposing them on `PanePreviewFontSizing` or by moving them to a shared `MobileFontFit` namespace. (Implementation plan picks one.)

### Decision function

```swift
public enum TerminalWidthLayout {
    public enum Decision: Equatable {
        case useConfigFont
        case fitFont(pointSize: Float)
    }

    public static func decide(
        containerWidth: CGFloat,
        serverCols: UInt16?,
        configFontSize: Float,
        isLeader: Bool
    ) -> Decision {
        if isLeader { return .useConfigFont }
        guard let serverCols, serverCols > 0, containerWidth > 0 else {
            return .useConfigFont
        }
        let targetCellWidth = (containerWidth / CGFloat(serverCols)) * safetyScale
        let targetFontSize = Float(targetCellWidth / monospaceAspect)
        if targetFontSize >= configFontSize {
            return .useConfigFont
        }
        return .fitFont(pointSize: max(minimumFontSize, targetFontSize))
    }
}
```

Rules in order:
1. `isLeader == true` → `.useConfigFont` (caller treats this as "leave any in-place override alone")
2. `serverCols` not yet known or container not yet measured → `.useConfigFont`
3. `targetFontSize ≥ configFontSize` → `.useConfigFont` (already fits at base font; do nothing)
4. Otherwise → `.fitFont(pointSize: max(min, target))`

### State machine

```
                ┌──────────────────────────┐
                │      Not-leader          │
                │  TerminalWidthLayout     │
                │  drives font on every    │
                │  containerWidth /        │
                │  serverGrid change       │
                └─────────┬────────────────┘
                          │
        ┌─────────────────┼─────────────────┐
   keystroke           pinch begin       long-press begin
        │                 │                  │
        ▼                 ▼                  ▼
        ┌────────────────────────────────────────┐
        │              Leader                    │
        │  • Last-applied font is the baseline   │
        │  • TerminalWidthLayout no longer       │
        │    drives the controller config        │
        │  • libghostty's pinch mutates font →   │
        │    cellWidth → onResize → server gets  │
        │    a resize envelope                   │
        └────────────────────────────────────────┘
```

The state is per-`SessionClient` and lives on `isSizeLeader: Bool` (already exists).

### Data flow when not-leader

```
server `grid` envelope                  device rotation / split resize
        │                                       │
        ▼                                       ▼
SessionClient.serverGrid              RootView GeometryReader
        │                                       │
        └─────────────┬─────────────────────────┘
                      ▼
       TerminalWidthLayout.decide(...)
                      │
                      ▼
       .fitFont(pointSize) or .useConfigFont
                      │
                      ▼
controller.updateConfigSource(.generated(
    appendingFontSizeOverride(baseConfig, fontSize: pointSize)
))
                      │
                      ▼
libghostty rebuilds → new cellWidthPixels → onResize callback
                      │
                      ▼
SessionClient.handleViewport — !isSizeLeader → memoize only, no send
```

### Data flow on leadership claim (any of three triggers)

```
gesture / keystroke event
        │
        ▼
SessionClient.claimLeadershipIfNeeded()
        │
        ├─ isSizeLeader = true
        ├─ send current (lastIOSViewport.cols, .rows) to server
        │
        ▼
RootView observes isSizeLeader: false → true
        │
        ▼
RootView stops calling TerminalWidthLayout.decide for this session.
The currently-applied controller config (override or base) stays put.
```

The caller's reconciliation rule:

- While `!isSizeLeader`: re-run `decide` on every `(containerWidth, serverGrid, configFontSize)` change. If output is `.fitFont(p)`, apply that override. If output is `.useConfigFont` AND an override is currently applied, revert to base config.
- On the transition `isSizeLeader: false → true`: stop reconciling for this session. Whatever override (or base) is currently applied stays put. `decide` is no longer called.

### PTY width persistence (detach bug)

The Mac client almost certainly emits a resize on attach — likely from libghostty's initial viewport-callback firing before its `NSView` has its final size, producing a small `(cols, rows)` that lands at zmx. The fix is the Mac-side mirror of IOS-6.5: the Mac client memoizes viewport changes but does not emit a `TIOCSWINSZ` until the first user-input event after attach.

This is its own work item. The implementation plan will:
1. Add a failing integration test capturing the invariant (zmx PTY cols unchanged across Mac alone-detach + alone-reattach with no user input).
2. Locate the offending emission (suspects, in priority order: `Sources/Graftty/Terminal/TerminalManager.swift` attach lifecycle; libghostty surface viewport callback wiring; zmx attach handshake).
3. Apply the "no resize before first user input after attach" rule.

## Testing

### Unit tests

**`Tests/GrafttyMobileKitTests/Terminal/TerminalWidthLayoutTests.swift`** (rewrite):
- `isLeader == true` → `.useConfigFont`
- `serverCols == nil` → `.useConfigFont`
- `serverCols × configCellWidth ≤ containerWidth` → `.useConfigFont`
- `serverCols × configCellWidth > containerWidth` → `.fitFont(pointSize:)` with the expected size
- Floor: `targetFontSize < minimumFontSize` → `.fitFont(pointSize: minimumFontSize)`

**`Tests/GrafttyMobileKitTests/Session/SessionClientTests.swift`** (add cases):
- Long-press claim event → `isSizeLeader == true`, server received a `resize` envelope
- Pinch claim event → same
- Applying a fit-font override (simulated via `handleViewport` with the post-rebuild cell width while `!isSizeLeader`) does **not** claim leadership
- Tap-only interaction does **not** claim leadership

**`Tests/GrafttyMobileKitTests/UI/PaneLayoutViewTests.swift`** (extend, or create if absent):
- iPad split-view leaf where one leaf's width forces font-fit and another's doesn't — assert each leaf's controller gets the right font override

### Integration / E2E

**Detach bug repro** (Mac-side; placement TBD by investigation):
- Synthetic zmx session at cols=200, rows=50
- Mac client attaches → records cols=200
- Mac client detaches
- Mac client reattaches with no user input
- Assert: PTY cols still 200

If the existing test infra can't drive a zmx session at this level, add the minimum scaffolding needed (a fake zmx process or a fixture wrapping `TerminalManager` in isolation).

### Inventory updates

`Tests/GrafttyTests/Specs/IpadTodo.swift` — update IPAD-2.5 entry's EARS text to match the new behavior, keep `.disabled` until iPad implementation lands (if iPad work is staged separately).

## Open Questions

None blocking. Two implementation-time decisions:

1. **Constant sharing** — move `monospaceAspect / safetyScale / minimumFontSize` to a shared namespace (e.g., `MobileFontFit`), or re-export from `PanePreviewFontSizing`. Implementation plan picks one.
2. **Detach root cause** — exact file/line lives behind an investigation step in the implementation plan. The spec only commits to the invariant.

## Out of Scope

- Web client behavior. WEB-5.5 already sizes the web grid to fill the host element; the web client is effectively always-leader-shaped for its own size.
- Vertical layout / scrollback — only horizontal sizing changes here.
- Changing what "leadership" *means* server-side (still: last resize wins).
- An explicit "give up leadership" affordance — leadership is sticky for the session lifetime once claimed.
- Multi-client leadership negotiation (two iOS devices both claiming).
