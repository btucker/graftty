# iPad Render Throttle + Hardware Escape Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Quiet-but-visible iPad terminals render at ~1 fps instead of native (up to 120 Hz) rate, restoring full rate instantly on output/input/touch; and hardware-keyboard Escape reaches the PTY.

**Architecture:** A `TerminalRenderPace` throttle added to the libghostty-spm fork gates the per-surface `tick()` body; an app-side governor in `SessionClient` (mirroring the existing idle-watchdog pattern) drives it from the existing `recordActivity()` signal plus a new any-touch signal. Escape passthrough is a `pressesBegan` override on the keyboard input proxy.

**Tech Stack:** Swift, SwiftUI/UIKit, libghostty-spm fork (btucker/libghostty-spm@expose-selection-api), Swift Testing, iOS Simulator via xcodebuild.

**Design spec:** `docs/superpowers/specs/2026-07-10-ipad-render-throttle-design.md` — read it first.

## Global Constraints

- The graftty worktree is `/Users/btucker/projects/graftty/.worktrees/ipad-improvements` (branch `ipad-improvements`). The fork checkout is `/Users/btucker/projects/graftty-libghostty-fork/libghostty-spm` (branch `expose-selection-api`, remote `origin` = github.com/btucker/libghostty-spm).
- **The graftty tree contains unrelated in-flight changes** (a keybindings refactor touching `GhosttyKeybindingsFetcher.swift`, `IPadRootLayout.swift`, and keybinding test files). NEVER run `git add -A` / `git add .` in the graftty repo — stage only the exact files your task created or modified. If one of your task's files overlaps an in-flight change, stop and report instead of committing.
- `swift test` on macOS does NOT compile `#if canImport(UIKit)` GrafttyMobileKit code (false-green). Anything mobile must be verified on the iOS Simulator:
  `xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -sdk iphonesimulator -configuration Debug -skipPackagePluginValidation -derivedDataPath /tmp/graftty-dd -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrafttyMobileKitTests/<ClassName> test`
- @spec conventions (repo CLAUDE.md): EARS phrasing, the test title IS the requirement, no literal `\"` escaped quotes inside @spec titles, run `python3 scripts/generate-specs.py` and commit the regenerated `SPECS.md` with any @spec change.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Fork — `TerminalRenderPace` + tick gating

**Files:**
- Create: `/Users/btucker/projects/graftty-libghostty-fork/libghostty-spm/Sources/GhosttyTerminal/Surface/TerminalRenderPace.swift`
- Modify: `/Users/btucker/projects/graftty-libghostty-fork/libghostty-spm/Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift` (property near line 30, `tick()` at ~line 204, `synchronizeMetrics()` at ~line 186 where `lastMetrics = metrics` is assigned)
- Modify: `/Users/btucker/projects/graftty-libghostty-fork/libghostty-spm/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift` (public forwarding property after the `configuration` property at ~line 58)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `public enum TerminalRenderPace: Equatable, Sendable { case full; case reduced(interval: TimeInterval) }` and `public var renderPace: TerminalRenderPace` on `UITerminalView` (default `.full`). Tasks 2–4 rely on these exact names.

- [ ] **Step 1: Sync the fork checkout**

```bash
cd /Users/btucker/projects/graftty-libghostty-fork/libghostty-spm
git fetch origin expose-selection-api && git checkout expose-selection-api && git pull --ff-only origin expose-selection-api
git status --short   # must be clean
```

- [ ] **Step 2: Create TerminalRenderPace.swift**

```swift
import Foundation

/// How often a mounted terminal surface runs its render tick.
/// Embedders drop quiet-but-visible terminals to `.reduced` (~1 fps)
/// to stop the display-link-driven Metal pipeline from redrawing an
/// unchanged screen at native refresh rate.
public enum TerminalRenderPace: Equatable, Sendable {
    /// Run the full tick body on every display-link fire (default).
    case full
    /// Run the tick body at most once per `interval` seconds.
    case reduced(interval: TimeInterval)
}
```

- [ ] **Step 3: Gate the coordinator tick**

In `TerminalSurfaceCoordinator.swift`, add near the other stored properties (after `configuration`, before `// MARK: - Display Link`):

```swift
    /// Embedder-controlled render throttle. While `.reduced`, `tick()`
    /// runs its body at most once per interval. `synchronizeMetrics()`
    /// resets the gate so resizes/rotations render immediately.
    var renderPace: TerminalRenderPace = .full

    private var lastThrottledTickAt: CFTimeInterval = 0
```

Replace `tick()` (keep the existing body lines exactly as they are inside the gate):

```swift
    func tick() {
        if case let .reduced(interval) = renderPace {
            let now = CACurrentMediaTime()
            guard now - lastThrottledTickAt >= interval else { return }
            lastThrottledTickAt = now
        }
        TerminalDebugLog.log(.render, "tick")
        controller?.tick()
        surface?.refresh()
        surface?.draw()
        onPostRender?()
    }
```

In `synchronizeMetrics()`, immediately after the existing `lastMetrics = metrics` assignment, add:

```swift
        lastThrottledTickAt = 0
```

If the file doesn't already import QuartzCore (for `CACurrentMediaTime`), add `import QuartzCore` at the top. Note the whole tick body — including `controller?.tick()` (`ghostty_app_tick`) — is gated: this is deliberate (design decision: fewer CPU wakeups; promotion to `.full` happens app-side on any event that needs prompt attention).

- [ ] **Step 4: Expose on UITerminalView**

In `UITerminalView.swift`, after the `configuration` forwarding property:

```swift
        /// Embedder-controlled render throttle (see `TerminalRenderPace`).
        public var renderPace: TerminalRenderPace {
            get { core.renderPace }
            set { core.renderPace = newValue }
        }
```

- [ ] **Step 5: Build both platforms**

```bash
cd /Users/btucker/projects/graftty-libghostty-fork/libghostty-spm
swift build 2>&1 | tail -2                       # macOS: expect "Build complete!"
xcodebuild build -scheme GhosttyTerminal -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation 2>&1 | tail -3   # expect BUILD SUCCEEDED
```

If the scheme name is wrong, run `xcodebuild -list` in that directory and use the package/target scheme it prints. macOS `TerminalSurfaceCoordinator` is shared with the Mac app — the `.full` default means Mac behavior is unchanged; the build check confirms it compiles there.

- [ ] **Step 6: Commit and push the fork**

```bash
cd /Users/btucker/projects/graftty-libghostty-fork/libghostty-spm
git add Sources/GhosttyTerminal/Surface/TerminalRenderPace.swift Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift
git commit -m "Add embedder-controlled TerminalRenderPace tick throttle

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push origin expose-selection-api
git rev-parse HEAD   # report this SHA — Task 2 verifies Package.resolved picks it up
```

---

### Task 2: Graftty — bump libghostty-spm pin

**Files:**
- Modify: `/Users/btucker/projects/graftty/.worktrees/ipad-improvements/Package.resolved` (via `swift package update`, not by hand)

**Interfaces:**
- Consumes: the pushed fork SHA from Task 1.
- Produces: a graftty tree where `import GhosttyTerminal` exposes `TerminalRenderPace` and `UITerminalView.renderPace`. Tasks 3–4 depend on this.

- [ ] **Step 1: Update the pin**

```bash
cd /Users/btucker/projects/graftty/.worktrees/ipad-improvements
swift package update libghostty-spm 2>&1 | tail -3
git diff Package.resolved | grep revision   # must show the Task 1 SHA as the new revision
```

- [ ] **Step 2: Verify both builds**

```bash
swift build 2>&1 | tail -2   # expect "Build complete!"
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -sdk iphonesimulator -configuration Debug -skipPackagePluginValidation -derivedDataPath /tmp/graftty-dd -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3   # expect BUILD SUCCEEDED
```

- [ ] **Step 3: Commit (Package.resolved only)**

```bash
git add Package.resolved
git commit -m "chore: bump libghostty-spm for TerminalRenderPace

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: SessionClient render-pace governor (TDD)

**Files:**
- Modify: `Sources/GrafttyMobileKit/Session/SessionClient.swift` (property near `renderActivity` at ~line 216; watchdog beside `startIdleWatchdog()` at ~line 469; hooks in `recordActivity()` ~line 493, `start()` call site ~line 346, `stop()` ~line 605)
- Modify: `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift` (constants beside `previewIdleThreshold` in the `extension SessionClient`)
- Create: `Tests/GrafttyMobileKitTests/Session/SessionRenderPaceTests.swift`

**Interfaces:**
- Consumes: `TerminalRenderPace` from Task 2's bump.
- Produces: `SessionClient.renderPace: TerminalRenderPace` (published, `private(set)`), `SessionClient.renderPaceQuietDelay: TimeInterval == 5`, `SessionClient.reducedRenderPaceInterval: TimeInterval == 1.0`, and public `wakeRenderer()` (already exists) as the external promotion hook. Task 4 reads `client.renderPace` and calls `client.wakeRenderer()`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/GrafttyMobileKitTests/Session/SessionRenderPaceTests.swift`. Mirror the construction pattern from `SessionReconnectTests.swift` (same directory): its `IdleWS`, `FactoryRecorder`, `quiesce()` helpers and `SessionClient(sessionName:webSocketFactory:clock:backoffSchedule:)` init with a `VirtualClock` (defined in `Tests/GrafttyMobileKitTests/Auth/VirtualClock.swift`; `advance(by:)` resumes due sleepers). Note the governor watchdog only arms after `start()` — check how `SessionReconnectTests` drives `start()` and mirror it; if its tests rely on construction alone, call `client.start()` explicitly and `quiesce()` before advancing the clock.

```swift
#if canImport(UIKit)
import Foundation
import GhosttyTerminal
import Testing
@testable import GrafttyMobileKit

@Suite
@MainActor
struct SessionRenderPaceTests {
    final class IdleWS: WebSocketClient, @unchecked Sendable {
        func send(_ frame: WebSocketFrame) async throws {}
        func receive() async throws -> WebSocketFrame {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw CancellationError()
        }
        func close() {}
    }

    func quiesce() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func makeStartedClient(clock: VirtualClock) async -> SessionClient {
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: { IdleWS() },
            clock: clock,
            backoffSchedule: [1]
        )
        client.start()
        await quiesce()
        return client
    }

    @Test("""
    @spec IOS-10.8: While a terminal session has received no output or user interaction for 5 seconds, the application shall reduce that surface's render pace to at most one frame per second while keeping the surface mounted.
    """)
    func quietSessionReducesRenderPace() async {
        let clock = VirtualClock()
        let client = await makeStartedClient(clock: clock)
        defer { client.stop() }

        #expect(client.renderPace == .full)
        clock.advance(by: SessionClient.renderPaceQuietDelay + 0.1)
        await quiesce()

        #expect(client.renderPace == .reduced(interval: SessionClient.reducedRenderPaceInterval))
    }

    @Test("""
    @spec IOS-10.9: When output, input, or a touch arrives while a surface is render-reduced, the application shall restore full render pace immediately.
    """)
    func activityRestoresFullPace() async {
        let clock = VirtualClock()
        let client = await makeStartedClient(clock: clock)
        defer { client.stop() }

        clock.advance(by: SessionClient.renderPaceQuietDelay + 0.1)
        await quiesce()
        #expect(client.renderPace != .full)

        client.wakeRenderer()
        #expect(client.renderPace == .full)

        // Re-arms: goes quiet again after another full quiet window.
        clock.advance(by: SessionClient.renderPaceQuietDelay + 0.1)
        await quiesce()
        #expect(client.renderPace == .reduced(interval: SessionClient.reducedRenderPaceInterval))
    }

    @Test func activityBeforeDeadlineKeepsFullPace() async {
        let clock = VirtualClock()
        let client = await makeStartedClient(clock: clock)
        defer { client.stop() }

        clock.advance(by: 3)
        client.wakeRenderer()
        await quiesce()
        clock.advance(by: 3)
        await quiesce()

        #expect(client.renderPace == .full)   // only 3s since last activity
    }
}
#endif
```

- [ ] **Step 2: Run to verify RED**

```bash
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -sdk iphonesimulator -configuration Debug -skipPackagePluginValidation -derivedDataPath /tmp/graftty-dd -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrafttyMobileKitTests/SessionRenderPaceTests test 2>&1 | tail -5
```

Expected: compile FAILURE (`renderPace`/`renderPaceQuietDelay` undefined) — that is the RED state.

- [ ] **Step 3: Implement the governor**

In `SessionLifecycleEnvironment.swift`, inside the existing `extension SessionClient` next to `previewIdleThreshold`:

```swift
    /// Quiet window before a mounted surface's render pace drops to
    /// `.reduced` (~1 fps). Distinct from `idleThreshold`, which
    /// unmounts the surface entirely (previews only).
    public nonisolated static let renderPaceQuietDelay: TimeInterval = 5
    public nonisolated static let reducedRenderPaceInterval: TimeInterval = 1.0
```

In `SessionClient.swift`, next to `renderActivity` (~line 216):

```swift
    public private(set) var renderPace: TerminalRenderPace = .full
```

(`import GhosttyTerminal` is already present in this file — verify; add if not.)

Next to `idleWatchdogTask` (~line 232):

```swift
    @ObservationIgnored
    private var paceWatchdogTask: Task<Void, Never>?
```

Beside `startIdleWatchdog()` (~line 469) — same loop shape, no finite-threshold guard:

```swift
    @MainActor
    private func startPaceWatchdog() {
        paceWatchdogTask?.cancel()
        paceWatchdogTask = Task { @MainActor [weak self] in
            while let self, !self.stopped, self.renderPace == .full {
                let elapsed = self.clock.now.timeIntervalSince(self.lastActivityAt)
                let remaining = Self.renderPaceQuietDelay - elapsed
                if remaining <= 0 {
                    self.renderPace = .reduced(interval: Self.reducedRenderPaceInterval)
                    return
                }
                do {
                    try await self.clock.sleep(for: remaining)
                } catch {
                    return
                }
            }
        }
    }
```

In `recordActivity()` (~line 493), after the existing `lastActivityAt = clock.now`:

```swift
        if renderPace != .full {
            renderPace = .full
            startPaceWatchdog()
        }
```

At the `startIdleWatchdog()` call in `start()` (~line 346), add `startPaceWatchdog()` on the next line. In `stop()` (~line 605), mirror the idle-watchdog cancellation:

```swift
        paceWatchdogTask?.cancel()
        paceWatchdogTask = nil
```

- [ ] **Step 4: Run to verify GREEN**

Same xcodebuild command as Step 2. Expected: `Test run with 3 tests in 1 suite passed`.

- [ ] **Step 5: Regenerate SPECS.md and commit**

```bash
cd /Users/btucker/projects/graftty/.worktrees/ipad-improvements
grep -n "IOS-10.8\|IOS-10.9" SPECS.md   # confirm they were free before; regenerate:
python3 scripts/generate-specs.py
git add Sources/GrafttyMobileKit/Session/SessionClient.swift Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift Tests/GrafttyMobileKitTests/Session/SessionRenderPaceTests.swift SPECS.md
git commit -m "feat(ipad): reduce render pace for quiet terminal sessions

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

If `IOS-10.8`/`IOS-10.9` are already taken in SPECS.md, use the next free IOS-10.x numbers in both test titles and rerun the generator.

---

### Task 4: Touch signal + view wiring

**Files:**
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift` (new `renderPace` + `onUserInteraction` parameters; any-touch recognizer on `TerminalInputContainerView`)
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift` (the `TerminalPaneView(...)` construction in `activeTerminal` at ~line 804)
- Modify: any other `TerminalPaneView(` construction sites that have a `SessionClient` in scope (find with `grep -rn "TerminalPaneView(" Sources/GrafttyMobileKit/`)
- Test: `Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift`

**Interfaces:**
- Consumes: `SessionClient.renderPace` and `wakeRenderer()` from Task 3; `UITerminalView.renderPace` from Tasks 1–2.
- Produces: `TerminalPaneView(renderPace:onUserInteraction:)` parameters (both defaulted: `.full` / `nil`) so existing call sites keep compiling.

- [ ] **Step 1: Write the failing test**

Add to `TerminalPaneViewTests.swift` (mirror the existing container-based test style in that file):

```swift
    @Test("any touch on the terminal container fires onUserInteraction")
    func touchBeganFiresUserInteraction() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var fired = 0
        container.onUserInteraction = { fired += 1 }

        container.simulateAnyTouchBeganForTesting()

        #expect(fired == 1)
    }
```

- [ ] **Step 2: Run to verify RED**

Same xcodebuild command targeting `-only-testing:GrafttyMobileKitTests/TerminalPaneViewTests`. Expected: compile failure (`onUserInteraction` undefined).

- [ ] **Step 3: Implement**

In `TerminalPaneView.swift`, add a gesture-recognizer class near the bottom of the file (above the `UIKeyModifierFlags` extension):

```swift
/// Observes touch-begin without claiming the gesture: reports, then
/// immediately fails so libghostty's pan/pinch and the selection
/// recognizers proceed untouched. Powers render-pace promotion —
/// local scrolling renders without host output, so a finger on the
/// surface must count as activity.
final class AnyTouchObserverGestureRecognizer: UIGestureRecognizer {
    var onTouchBegan: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchBegan?()
        state = .failed
    }
}
```

On `TerminalInputContainerView`:

```swift
    public var onUserInteraction: (() -> Void)?

    private lazy var anyTouchObserver: AnyTouchObserverGestureRecognizer = {
        let r = AnyTouchObserverGestureRecognizer()
        r.cancelsTouchesInView = false
        r.onTouchBegan = { [weak self] in self?.onUserInteraction?() }
        return r
    }()
```

Register it in `setup()` alongside the existing recognizers: `addGestureRecognizer(anyTouchObserver)`. Add the test seam next to the other `*ForTesting` seams:

```swift
    func simulateAnyTouchBeganForTesting() {
        onUserInteraction?()
    }
```

On `TerminalPaneView`: add `public let renderPace: TerminalRenderPace` and `public let onUserInteraction: (() -> Void)?` properties, init parameters `renderPace: TerminalRenderPace = .full, onUserInteraction: (() -> Void)? = nil` (keep parameter order: insert after `hardwareKeyboardCommands`), and in BOTH `makeUIView` and `updateUIView`:

```swift
        view.terminalView.renderPace = renderPace
        view.onUserInteraction = onUserInteraction
```

In `RootView.swift`'s `activeTerminal` `TerminalPaneView(...)` call, add (after `hardwareKeyboardCommands:`):

```swift
            renderPace: client.renderPace,
            onUserInteraction: { [weak client] in client?.wakeRenderer() },
```

Wire the same two arguments at any other `TerminalPaneView(` construction site that has a `SessionClient` in scope (grep per Files above); leave sites without a client on the defaults.

- [ ] **Step 4: Run to verify GREEN**

Same command as Step 2. Expected: all `TerminalPaneViewTests` pass, including pre-existing ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift Sources/GrafttyMobileKit/App/RootView.swift Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift
# plus any other files you wired in Step 3
git commit -m "feat(ipad): wire render pace and touch promotion into terminal views

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Hardware Escape passthrough (TDD)

**Files:**
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift` (`TerminalSoftwareKeyboardProxyView` at ~line 453; `SoftwareKeyboardInput` struct at ~line 16; wiring in `makeUIView`/`updateUIView` at ~lines 122-124/136-138)
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift` (the `softwareKeyboardInput: .init(...)` construction at ~line 808)
- Test: `Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift`

**Interfaces:**
- Consumes: `SessionClient.sendEscape()` (exists, `SessionClient.swift:564`).
- Produces: `SoftwareKeyboardInput.sendEscape: () -> Void` closure member; `TerminalSoftwareKeyboardProxyView.handleKeyPresses(keyCodes:) -> Bool` (internal, the testable decision seam).

**Background for the implementer:** all keyboard input routes through `TerminalSoftwareKeyboardProxyView` (a `UIView + UIKeyInput` that is the first responder — libghostty's own view is swizzled out of the responder chain). `UIKeyInput` delivers only printable text and backspace; a hardware Escape arrives as a key press event and is currently discarded. Do not touch the `hitTest` override (IOS-6.8 pass-through) or gesture recognizers (IOS-6.17).

- [ ] **Step 1: Write the failing tests**

Add to `TerminalPaneViewTests.swift`:

```swift
    @Test("""
    @spec IOS-6.18: When a hardware keyboard Escape press reaches the terminal input proxy, the application shall send ESC to the session rather than discarding the press.
    """)
    func hardwareEscapePressSendsEscape() {
        let proxy = TerminalSoftwareKeyboardProxyView(frame: .zero)
        var escapes = 0
        proxy.sendEscapeHandler = { escapes += 1 }

        let handled = proxy.handleKeyPresses(keyCodes: [.keyboardEscape])

        #expect(handled)
        #expect(escapes == 1)
    }

    @Test("non-escape key presses fall through to UIKit")
    func nonEscapePressesAreNotConsumed() {
        let proxy = TerminalSoftwareKeyboardProxyView(frame: .zero)
        var escapes = 0
        proxy.sendEscapeHandler = { escapes += 1 }

        let handled = proxy.handleKeyPresses(keyCodes: [.keyboardA])

        #expect(!handled)
        #expect(escapes == 0)
    }
```

- [ ] **Step 2: Run to verify RED**

Same xcodebuild command targeting `TerminalPaneViewTests`. Expected: compile failure (`sendEscapeHandler` / `handleKeyPresses` undefined).

- [ ] **Step 3: Implement**

On `TerminalSoftwareKeyboardProxyView`:

```swift
    var sendEscapeHandler: (() -> Void)?

    /// Decision seam for `pressesBegan` — split out because `UIPress`/
    /// `UIKey` cannot be constructed in tests. Returns true when the
    /// presses were consumed.
    func handleKeyPresses(keyCodes: [UIKeyboardHIDUsage]) -> Bool {
        guard sendEscapeHandler != nil, keyCodes.contains(.keyboardEscape) else {
            return false
        }
        sendEscapeHandler?()
        return true
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let keyCodes = presses.compactMap { $0.key?.keyCode }
        if handleKeyPresses(keyCodes: keyCodes) {
            return
        }
        super.pressesBegan(presses, with: event)
    }
```

Extend `SoftwareKeyboardInput` with a third closure, keeping the existing two:

```swift
        public let sendEscape: () -> Void

        public init(
            insertText: @escaping (String) -> Void,
            deleteBackward: @escaping () -> Void,
            sendEscape: @escaping () -> Void
        ) {
            self.insertText = insertText
            self.deleteBackward = deleteBackward
            self.sendEscape = sendEscape
        }
```

In `makeUIView` and `updateUIView`, beside the existing insert/delete handler assignments:

```swift
        view.inputProxy.sendEscapeHandler = softwareKeyboardInput?.sendEscape
```

In `RootView.swift`'s `softwareKeyboardInput: ... .init(...)` construction (~line 808), add the new argument:

```swift
                sendEscape: { client.sendEscape() }
```

Fix any other `SoftwareKeyboardInput(` construction sites the compiler flags (grep to confirm; tests may construct it).

- [ ] **Step 4: Run to verify GREEN**

Same command as Step 2. Expected: all `TerminalPaneViewTests` pass.

- [ ] **Step 5: Regenerate SPECS.md, commit**

```bash
grep -n "IOS-6.18" SPECS.md   # confirm free before; then:
python3 scripts/generate-specs.py
git add Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift Sources/GrafttyMobileKit/App/RootView.swift Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift SPECS.md
git commit -m "fix(ipad): pass hardware Escape through the keyboard proxy

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

If IOS-6.18 is taken, use the next free IOS-6.x and rerun the generator.

---

### Task 6: Full verification

**Files:** none created; runs the suites.

- [ ] **Step 1: iOS Simulator — all touched test classes**

```bash
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -sdk iphonesimulator -configuration Debug -skipPackagePluginValidation -derivedDataPath /tmp/graftty-dd -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrafttyMobileKitTests/SessionRenderPaceTests -only-testing:GrafttyMobileKitTests/TerminalPaneViewTests -only-testing:GrafttyMobileKitTests/SessionReconnectTests test 2>&1 | grep -E "Test run|failed" | tail -5
```

Expected: all pass. (`SessionReconnectTests` is included because Task 3 touched `SessionClient`'s watchdog lifecycle.)

- [ ] **Step 2: macOS suite + spec check**

```bash
swift build 2>&1 | tail -1 && python3 scripts/generate-specs.py --check && echo SPECS-OK
swift test 2>&1 | tail -1
```

Expected: build complete, SPECS-OK, and the test run passing (the WebServer zmx-integration suite has a documented pre-existing WEB-5.6 flake — 2–3 issues in that suite only are ignorable; anything else is not).

- [ ] **Step 3: Report** — do NOT push; the main session pushes after review. Report: fork SHA, graftty commits created, test tallies, and any deviations.
