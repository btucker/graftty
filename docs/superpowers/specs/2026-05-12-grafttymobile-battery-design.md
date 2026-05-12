# GrafttyMobile Battery — Design

Date: 2026-05-12
Branch: `grafttymobile-battery`
Status: Design, awaiting user review

## Problem

GrafttyMobile drains battery aggressively whenever it has been open recently. The complaint covers two scenarios: the app is foregrounded on a screen (fullscreen pane or the preview tiles), and the period immediately after the user backgrounds the app or locks the phone.

## Root cause

Two foundational findings from reading the libghostty-spm package (vendored via SourcePackages) and our own scene-phase handling:

1. **libghostty redraws every display-link frame, unconditionally.** `TerminalSurfaceCoordinator.tick()` (libghostty-spm `Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift:204`) submits a Metal command buffer on every CADisplayLink callback regardless of whether the terminal content has changed. On a ProMotion iPhone that is 120 GPU draws per second per visible terminal. On `WorktreeDetailView` with the current `maxLivePanePreviews = 2`, that is two preview surfaces drawing alongside the host pane.

2. **`MSDisplayLink` (the shared driver libghostty uses) only pauses on `UIApplication.didEnterBackgroundNotification`.** It does not pause on `.inactive`, and it does not set `preferredFrameRateRange`. So during the entire `.inactive` window (lock-screen pull-down, Control Center, app switcher, incoming call) all visible terminals continue to tick at 60–120 Hz.

3. **Our scene-phase gates only fire on `.background`.** `RootView.driveConnection` (`Sources/GrafttyMobileKit/App/RootView.swift:243`) and `WorktreeDetailView.driveLifecycle` (`Sources/GrafttyMobileKit/UI/WorktreeDetailView.swift:78`) both check `scenePhase == .background` for teardown. The `.inactive` window is invisible to us today.

4. **WebSocket reconnect is unimplemented.** `SessionClient.start()`'s receive loop has `catch { break }` and `HostController.backoffSchedule(attempts:)` is dead code. IOS-7.4 specifies exponential backoff but no test or production code path implements it. This becomes user-visible the moment we start cycling WSes more frequently (which IOS-10.1's `.inactive` teardown does).

## Goals

- Cut foreground idle battery cost to roughly the cost of a static SwiftUI screen.
- Cut "phone locked but app still recent" cost to roughly zero (iOS will suspend us; we just need to stop fighting that).
- Implement IOS-7.4 properly so the new teardown frequency does not surface a pre-existing latent bug.

## Non-goals

- Forking libghostty-spm or MSDisplayLink to expose `preferredFrameRateRange`. The mount/unmount approach captures the same wins without owning a fork.
- Persisting pane scrollback across idle pauses (out of scope; matches IOS-8.4).
- Background-mode entitlements. The app stays a normal foreground app and continues to be suspended on `.background` per iOS norms.

## Approach

Bundled change with three components, shippable as one PR or staged:

1. Implement IOS-7.4: auto-reconnect with backoff inside `SessionClient`.
2. Treat `.inactive` like `.background` for teardown; lower `maxLivePanePreviews` to 1.
3. Idle-pause the renderer: when a `SessionClient` has been quiet for `idleThreshold` seconds, unmount its `TerminalPaneView` and show a snapshot of the last frame in its place.

## Component 1 — Reconnect with exponential backoff (IOS-7.4)

### Refactor SessionClient WS ownership

Today `SessionClient.init(sessionName:, webSocket:, role:)` takes a constructed `WebSocketClient`. Change it to take a factory so the same `SessionClient` instance can survive across reconnect attempts:

```swift
public init(
    sessionName: String,
    webSocketFactory: @Sendable @escaping () -> WebSocketClient,
    backoffSchedule: [TimeInterval] = HostController.backoffSchedule(attempts: 6),
    clock: any Clock = SystemClock(),
    role: Role = .fullscreen
)
```

`SessionClient.live(baseURL:, sessionName:, role:)` (the only production caller, in `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift:31`) is updated to pass a closure that mints a fresh `URLSessionWebSocketClient` per attempt.

### Outer reconnect loop

`start()` becomes:

```swift
public func start() {
    runTask = Task { @MainActor [weak self] in
        var attempt = 0
        while let self, !self.stopped {
            self.ws = self.webSocketFactory()
            self.connectionState = .live
            attempt = 0
            do {
                try await self.runReceiveLoop()  // throws on error
            } catch is CancellationError {
                return
            } catch {
                guard !self.stopped else { return }
            }
            let delay = self.backoffSchedule[min(attempt, self.backoffSchedule.count - 1)]
            self.connectionState = .reconnecting(attempt: attempt + 1)
            attempt += 1
            do { try await self.clock.sleep(for: delay) }
            catch { return }
        }
    }
}
```

Successful connect resets `attempt = 0` (per IOS-7.4). Cancellation paths (`stopped`, `Task.isCancelled`) bail cleanly from both the receive loop and any in-flight backoff sleep.

### New observable state

```swift
public enum ConnectionState: Equatable {
    case live
    case reconnecting(attempt: Int)
}
public private(set) var connectionState: ConnectionState = .live
```

This is orthogonal to `SingleSessionView`'s existing `connection: ConnectionState` enum (which tracks `connecting`/`live`/`suspended`/`ended` — session existence and scene-phase concerns, not WS health).

### UI

`SingleSessionView` gains a thin overlay banner shown when `client?.connectionState != .live`:

> ⚠ Reconnecting… (attempt 3) &nbsp; [Reconnect now] &nbsp; [Back to sessions]

"Reconnect now" calls `SessionClient.forceReconnectNow()` which cancels the current backoff sleep and starts a fresh attempt with `attempt = 0`. "Back to sessions" pops the nav stack.

Preview SessionClients use the same reconnect logic with no banner — they are read-only thumbnails and the user can tap into fullscreen to see the live state.

### Clock abstraction

The local `Clock` protocol in `Sources/GrafttyMobileKit/Auth/Clock.swift` currently only exposes `var now: Date` (used by `BiometricGate`). Extend it with `func sleep(for: TimeInterval) async throws`. `SystemClock` wraps `Task.sleep(nanoseconds:)`. Tests inject a virtual clock whose `sleep` is a `CheckedContinuation` controlled by the test harness so backoff advances on demand.

### Testing

Inject a mock `WebSocketClient` factory and a virtual `Clock`. Cover:

- Open failure → state becomes `.reconnecting(1)` after one schedule entry of delay.
- Successive failures escalate per `HostController.backoffSchedule`.
- Successful connect resets `attempt` to 0 on the next failure.
- Receive-mid-session error triggers reconnect.
- `forceReconnectNow()` cancels backoff and restarts attempts at 0.
- `stop()` during backoff sleep cancels cleanly.

Tests are added fresh under `Tests/GrafttyMobileKitTests/Session/SessionReconnectTests.swift` (no `Tests/GrafttyMobileKitTests/Specs/` directory exists yet for the mobile target; if backlog inventory files get added for IOS-10.x stubs they live there, but IOS-7.4 is implemented now and goes straight to a real test file).

## Component 2 — Inactive-phase teardown + preview cap

### `LiveSessionReadiness.shouldTearDown(scene:)`

Add a single source of truth:

```swift
public static func shouldTearDown(scene: ScenePhase) -> Bool {
    scene == .inactive || scene == .background
}
```

Both `RootView.driveConnection` and `WorktreeDetailView.driveLifecycle` replace their `scenePhase == .background` checks with `LiveSessionReadiness.shouldTearDown(scene:)`. `dialKey` and `PoolKey` already include `scenePhase`, so the `.task(id:)` re-fires on `.inactive` and the new teardown branch wins.

On return to `.active`, the existing `.suspended → verifyThenOpen() → openWebSocket()` path runs (IOS-7.2/7.3) and the user is back live. With Component 1 in place, transient WS failures during this rehydration are handled by the reconnect loop.

### Preview cap

Lower `maxLivePanePreviews` in `Sources/GrafttyMobileKit/UI/WorktreeDetailView.swift:6` from `2` to `1`. The existing `PanePreviewClientPool.update(layout:, maxLivePreviews:)` already supports this — `prefix(1)` keeps the first leaf live and other tiles render their non-preview content unchanged.

### Risk

Low. The behavior change is that brief `.inactive` blips (Control Center, notification banner) now cost a `.suspended → .live` round-trip on return. With Component 1's reconnect handling, a transient network failure during that round-trip is no longer user-visible.

## Component 3 — Idle-pause renderer

### State machine on SessionClient

```swift
public enum RenderActivity: Equatable {
    case active
    case idle
}
public private(set) var renderActivity: RenderActivity = .active

@ObservationIgnored private var lastActivityAt: Date
@ObservationIgnored private var idleWatchdog: Task<Void, Never>?

private let idleThreshold: TimeInterval = 30  // tuneable
```

### Activity tracking

`lastActivityAt = clock.now` is bumped on:

- Every binary frame received in `runReceiveLoop()`. If currently `.idle`, also flip to `.active`.
- Every input-send method (`sendBinary`, `submitReturn`, `insertNewline`, `sendSoftwareKeyboardText`, `deleteBackward`, `sendEscape`, `sendTab`, `sendArrow`, `sendControl`).
- `wakeRenderer()` (called from the snapshot view's tap handler).

### Watchdog

A single `idleWatchdog: Task` started in `start()`. It loops:

```swift
while !stopped {
    try? await clock.sleep(for: 5)
    if stopped { return }
    if renderActivity == .active,
       clock.now.timeIntervalSince(lastActivityAt) >= idleThreshold {
        renderActivity = .idle
    }
}
```

5-second check granularity means worst-case wake-to-idle latency is `idleThreshold + 5s`. Cheap and sufficient.

### View-tree swap

`SingleSessionView.terminalContent` branches on `client.renderActivity`:

```swift
switch client.renderActivity {
case .active:
    TerminalPaneView(session: client.session, controller: controller, ...)
case .idle:
    IdleSnapshotView(snapshot: client.idleSnapshot) {
        client.wakeRenderer()
    }
}
```

When SwiftUI flips from `.active` to `.idle`, the `TerminalPaneView` is removed from the tree. UIKit detaches its `UITerminalView` from the window, fires `didMoveToWindow(window: nil)`, and libghostty's existing lifecycle hook (`Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Lifecycle.swift:31-33`) calls `core.stopDisplayLink()` and `core.freeSurface()`. **No libghostty changes required.**

### Snapshot capture

Captured just before unmount, inside the dismantling path of `TerminalPaneView` or via a `UIViewRepresentable` wrapper that observes `renderActivity` and snapshots on the `.active → .idle` transition.

Primary implementation:

```swift
let renderer = UIGraphicsImageRenderer(bounds: terminalView.bounds)
let image = renderer.image { ctx in
    terminalView.layer.render(in: ctx.cgContext)
}
client.setIdleSnapshot(image)
```

**Implementation risk:** libghostty uses a Metal/IOSurface-backed CALayer. `CALayer.render(in:)` may not capture Metal content, producing a black frame. On-device validation is required before merge.

**Graceful fallback** if the snapshot is empty or rendering produces a black frame: render an `IdleSnapshotView` that uses a stylized placeholder — dimmed dark background, a small "Tap to wake" pill in a corner, a faint cursor-position dot at the last known cursor cell. This is functionally honest ("renderer is paused for battery"), works regardless of Metal snapshot quirks, and degrades gracefully on tap.

### UX details

- 30-second threshold: long enough that reading sessions are not interrupted.
- A subtle dim overlay (5% darken) plus a small "Tap to wake" pill in a corner — converts "frozen cursor" from a "broken app" read to an "intentionally paused" read.
- Tap on the snapshot wakes the renderer; the tap is **not** forwarded as input to the shell. This avoids stray keystrokes on first wake.
- Re-mount latency: libghostty must recreate its surface (`controller.createSurface(...)`). Expect ~50–100ms before the first live frame; the snapshot fades out as cover.

### Preview pool interaction

Each preview `SessionClient` independently idles out. Combined with `maxLivePanePreviews = 1` from Component 2, an idle `WorktreeDetailView` costs roughly the same as a static SwiftUI screen.

### Testing

- Virtual `Clock` advances time without waiting.
- Mock `WebSocketClient` emits bytes on command.
- Test: no bytes for `idleThreshold + 1s` → `.idle`.
- Test: byte every 5s for 60s → stays `.active`.
- Test: from `.idle`, byte arrives → `.active`.
- Test: from `.idle`, `wakeRenderer()` → `.active`.
- Test: any send-input method bumps `lastActivityAt`.
- Test: `stop()` cancels the watchdog.
- Snapshot fidelity: **manual on-device validation only**, flagged in the PR description.

## Spec changes

New section in `SPECS.md` (auto-generated from `@spec` annotations):

### IOS-10.x — Energy / render pacing

- **IOS-10.1**: While `scenePhase` is `.inactive` or `.background`, the application shall tear down active WebSocket connections and unmount live `TerminalPaneView` instances so that libghostty's display link stops.
- **IOS-10.2**: The `WorktreeDetailView` preview pool shall keep at most one live preview `SessionClient`.
- **IOS-10.3**: When a `SessionClient` has received no PTY bytes and processed no user input for ≥ `idleThreshold` (default 30 seconds), the application shall transition its `renderActivity` to `.idle`.
- **IOS-10.4**: While a `SessionClient` is in `.idle`, the corresponding view shall display a static snapshot of the last live frame in place of `TerminalPaneView`, and shall offer a tap target that resumes `.active`.
- **IOS-10.5**: When a `SessionClient` is `.idle` and a new PTY byte is received, the application shall transition its `renderActivity` to `.active` and remount `TerminalPaneView` within one runloop tick.

Existing **IOS-7.4** stays as-is (its EARS text is correct; only the implementation was missing).

## Files touched

New / modified Swift sources:

- `Sources/GrafttyMobileKit/Session/SessionClient.swift` — factory-based init; reconnect loop; `connectionState`; `renderActivity`; activity tracking; watchdog; snapshot setter; `wakeRenderer()`; `forceReconnectNow()`.
- `Sources/GrafttyMobileKit/Auth/Clock.swift` — extend with `sleep(for:) async throws`.
- `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift` — update `SessionClient.live(...)` to pass a factory; add `LiveSessionReadiness.shouldTearDown(scene:)`.
- `Sources/GrafttyMobileKit/App/RootView.swift` — replace `scenePhase == .background` with `LiveSessionReadiness.shouldTearDown(scene:)`; branch terminal view on `renderActivity`; mount reconnect banner; mount `IdleSnapshotView`.
- `Sources/GrafttyMobileKit/UI/WorktreeDetailView.swift` — same teardown swap; lower `maxLivePanePreviews` to `1`.
- `Sources/GrafttyMobileKit/UI/IdleSnapshotView.swift` (new) — UIImage + tap-to-wake placeholder + stylized fallback.
- `Tests/GrafttyMobileKitTests/Session/SessionReconnectTests.swift` (new) — IOS-7.4 coverage.
- `Tests/GrafttyMobileKitTests/Session/SessionIdleRendererTests.swift` (new) — IOS-10.3 / IOS-10.4 / IOS-10.5 coverage.
- `Tests/GrafttyMobileKitTests/App/SessionLifecycleTests.swift` — extend for IOS-10.1.
- `Tests/GrafttyMobileKitTests/UI/PreviewCapTests.swift` (new or extend existing) — IOS-10.2 coverage.
No `Tests/GrafttyMobileKitTests/Specs/` inventory file exists today; if we choose to track unimplemented IOS-10.x sub-requirements there, the file goes in this commit, otherwise all IOS-10.x specs land as real `@Test` annotations directly.

## Effort and sequencing

- Component 1: ~½ day. Lands first; everything else assumes it.
- Component 2: ~¼ day. Trivial after Component 1.
- Component 3: ~1 day plus ~½ day on-device snapshot validation.

Total: ~2–2.5 days. Recommended sequence: 1 → 2 → 3 in three separate commits on the branch; can be three PRs if review velocity matters, or one PR with three commits.

## Risks

- **Snapshot fidelity on Metal layers.** Mitigated by the stylized-placeholder fallback. Worst case the visual transition is uglier than ideal, but the battery win is unaffected.
- **Reconnect-banner UX surface area.** The banner is small and time-bounded (most reconnects succeed within 1–2s). Manual-testing during a deliberate Wi-Fi cut is the validation.
- **Re-mount latency on idle wake.** ~50–100ms before first live frame. If this feels too long, we add a brief crossfade or pre-warm the surface.

## Out of scope

- IOS-7.4 banner persistence across navigation.
- Detailed metrics / energy log instrumentation. Validation is via the iOS Settings → Battery view and Xcode's Energy gauge during manual testing.
- Patching MSDisplayLink for `preferredFrameRateRange`. Reconsider only if A+B do not move the needle in measurement.
