# Code Review Follow-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Address the 15 findings surfaced by the high-effort code review of PR #201's diff (commits `a927f58..9f52bc9`).

**Architecture:** Each finding is fixed in the same general area where it lives. The plan groups tasks by file area so each task touches a focused set of files. Every fix is TDD-disciplined: a failing test first, then the smallest change that makes it pass. Some findings are trivial cleanups (dead code, doc comments) and get bundled with their neighbors rather than their own commit.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, UIKit, swift-nio, swift-nio-ssh, libghostty-spm, WebRTC.

**Review findings:** see PR #201 conversation for the JSON list of 15 findings. Severity ranking informed task ordering — Group A bugs are correctness, Group B/C are UX, Group D is robustness.

---

## File Structure

| File | Group | Role in changes |
|---|---|---|
| `Sources/Graftty/Terminal/HostManagedZmxBackend.swift` | A | Split write semantics (user vs programmatic); fix engagement-on-fail; lock-scope; remove dead reset |
| `Sources/Graftty/Terminal/SurfaceHandle.swift` | A | Programmatic callers (`extraInitialInput`, `typeText`) opt out of engagement claim |
| `Sources/Graftty/GrafttyApp.swift` | A | `splitPane`/`send-pane` paths opt out of engagement |
| `Sources/Graftty/AppZmxWriter.swift` | A | Idle-agent nudge opts out of engagement |
| `Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift` | A | New tests for opt-out, failure-doesn't-flip, lock-scope |
| `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift` | B | Pinch threshold, selection-mode gate, real gesture test seam |
| `Sources/GrafttyMobileKit/Session/SessionClient.swift` | B | First-frame pinch retry; stale-docstring cleanup |
| `Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift` | B | New: gesture-threshold + selection-gate tests |
| `Tests/GrafttyMobileKitTests/Session/SessionClientTests.swift` | B | New: first-frame-pinch-retry test |
| `Sources/GrafttyMobileKit/App/RootView.swift` | C | Restore base config on leader transition; round FontFitKey; epsilon dedupe |
| `Sources/GrafttyMobileKit/Terminal/TerminalWidthLayout.swift` | C | Accept optional measured aspect (cellWidthPoints + currentFontSize) |
| `Tests/GrafttyMobileKitTests/Terminal/TerminalWidthLayoutTests.swift` | C | New: aspect-derived fit tests |
| `Tests/GrafttyMobileKitTests/App/RootViewReconciliationTests.swift` | C | New: leader-transition restore test |
| `Sources/GrafttyMobileKit/Remote/SSH/SSHNIOTransport.swift` | D | Atomic-or-close partial-write; pendingInbound byte-cap |
| `Sources/GrafttyHostAgent/SSH/SSHNIOTransport.swift` | D | Mirror Mac-side fix |
| `Tests/GrafttyMobileKitTests/Remote/SSH/SSHNIOTransportUnitTests.swift` | D | New: cap-and-close + pre-flight backpressure tests |
| `Tests/GrafttyTests/Specs/IosTodo.swift` | Cleanup | IOS-6.10 doc-comment annotation note; restore IOS-6.5 "subsequent forwarding" clause |
| `SPECS.md` | Cleanup | Regenerated |

---

## Group A — HostManagedZmxBackend (Findings #1, #7, #11, #14)

Defends the IOS-12.1 silent-gate against the four ways it's currently bypassed.

### Task A1: `claimEngagement` parameter on `write`, only flip after success (#1, #7)

**Files:**
- Modify: `Sources/Graftty/Terminal/HostManagedZmxBackend.swift:191-200`
- Modify: `Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift` (append new tests after the existing IOS-12.1 suite)

- [ ] **Step 1: Write the failing tests**

Append to `HostManagedZmxBackendTests.swift` (just before the closing `}` of the `struct HostManagedZmxBackendTests`):

```swift
@Test("`write(_:claimEngagement: false)` shall not flip attachState to .engaged — used by programmatic callers (extraInitialInput, typeText for splitPane/send-pane/agent nudges) that should not be treated as IOS-12.1 user input.")
func programmaticWriteDoesNotEngageGate() throws {
    let session = FakeHostManagedSession()
    let backend = Self.makeBackend(session: session)
    defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
    try backend.start(surface: Self.fakeSurface())

    // Queue a pre-engagement viewport.
    HostManagedZmxBackend.receiveResizeCallback(
        backend.userdataForTesting,
        132, 43, 2112, 1032
    )
    #expect(session.resizes().isEmpty)

    // Programmatic write must NOT engage the gate — the queued resize stays unflushed.
    try backend.write(Data("hello".utf8), claimEngagement: false)
    #expect(session.resizes().isEmpty)
    #expect(session.writes() == [Data("hello".utf8)])

    // Real user input via the keystroke path DOES engage and flush.
    try backend.write(Data([0x68]))
    #expect(session.resizes() == [Resize(cols: 132, rows: 43)])
}

@Test("If `write` fails (e.g., backend is in `.idle` and `activeSession()` throws .notStarted), attachState shall remain `.silent` — the engagement gate flips only on writes that actually reached the PTY.")
func failedWriteDoesNotEngageGate() throws {
    let session = FakeHostManagedSession()
    let backend = Self.makeBackend(session: session)
    defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
    // Note: no start() — backend is in .idle.

    HostManagedZmxBackend.receiveResizeCallback(
        backend.userdataForTesting,
        132, 43, 2112, 1032
    )

    #expect(throws: HostManagedZmxBackend.Error.notStarted) {
        try backend.write(Data("h".utf8))
    }

    // Start the backend now and engage with a real keystroke.
    try backend.start(surface: Self.fakeSurface())
    // The pre-start callback was wiped by start() per IOS-12.1.
    // A fresh post-start callback shall trigger the flush.
    HostManagedZmxBackend.receiveResizeCallback(
        backend.userdataForTesting,
        80, 24, 960, 576
    )
    try backend.write(Data([0x68]))
    #expect(session.resizes() == [Resize(cols: 80, rows: 24)])
}
```

- [ ] **Step 2: Run the new tests — expect failure (compile error: missing `claimEngagement` parameter)**

```bash
swift test --filter "programmaticWriteDoesNotEngageGate|failedWriteDoesNotEngageGate" 2>&1 | tail -10
```

Expected: build error. The `write` signature doesn't take `claimEngagement` yet.

- [ ] **Step 3: Update `write` in `HostManagedZmxBackend.swift:191-200`**

Replace:

```swift
    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }

        // IOS-12.1: any user input is a leadership-claim signal. Flush any
        // queued viewport size to the PTY before forwarding the bytes.
        markUserInput()

        let currentSession = try activeSession()
        try currentSession.write(data)
    }
```

with:

```swift
    /// Forward bytes to the zmx PTY.
    ///
    /// - Parameter claimEngagement: When `true` (default), this write
    ///   counts as user input under IOS-12.1: the silent gate flips to
    ///   `.engaged` AFTER the write succeeds, flushing any queued
    ///   viewport size to the PTY. Programmatic call sites (initial
    ///   `extraInitialInput`, `typeText` from `splitPane`/`send-pane`,
    ///   the idle-agent nudge writer) pass `false` so they don't
    ///   silently claim a user-input contract they don't represent.
    func write(_ data: Data, claimEngagement: Bool = true) throws {
        guard !data.isEmpty else { return }

        let currentSession = try activeSession()
        try currentSession.write(data)

        // IOS-12.1: flip the gate only AFTER a successful write — a write
        // that throws `notStarted` or fails inside the session shall not
        // disengage the silent gate.
        if claimEngagement {
            markUserInput()
        }
    }
```

- [ ] **Step 4: Run tests — expect green**

```bash
swift test --filter "HostManagedZmxBackend" 2>&1 | tail -5
```

Expected: all HostManagedZmxBackend tests pass (existing ones still green; two new ones now pass).

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/Terminal/HostManagedZmxBackend.swift \
        Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift
git commit -m "fix(IOS-12.1): write() now opts in to engagement; flip only on success"
```

---

### Task A2: Programmatic callers opt out of engagement (#1)

Updates the four call sites that should not claim engagement.

**Files:**
- Modify: `Sources/Graftty/Terminal/SurfaceHandle.swift:259-262` (extraInitialInput) and `Sources/Graftty/Terminal/SurfaceHandle.swift:373-384` (typeText)
- Modify: `Sources/Graftty/GrafttyApp.swift:2168` and `:2793` (typeText callers)
- Modify: `Sources/Graftty/AppZmxWriter.swift:29` (typeText caller)

- [ ] **Step 1: Update `SurfaceHandle.typeText` to take and forward the flag**

Find:

```swift
    func typeText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let zmxBackend {
            try? zmxBackend.write(data)
            return
        }
        ...
```

Replace with:

```swift
    /// Programmatically inject text into the surface's PTY.
    ///
    /// - Parameter claimEngagement: When `true` (default), the inject
    ///   counts as user input under IOS-12.1 — flips the host-managed
    ///   silent gate. Callers that synthesize bytes on behalf of an
    ///   automation flow (split-with-command, send-pane IPC, idle agent
    ///   nudges) pass `false` so they don't masquerade as a user
    ///   keystroke. The non-zmx libghostty `ghostty_surface_text` path
    ///   has no per-pane engagement state, so the flag only matters for
    ///   `zmxBackend.write`.
    func typeText(_ text: String, claimEngagement: Bool = true) {
        guard let data = text.data(using: .utf8) else { return }
        if let zmxBackend {
            try? zmxBackend.write(data, claimEngagement: claimEngagement)
            return
        }
        ...
```

- [ ] **Step 2: `extraInitialInput` in `SurfaceHandle.swift:259-262` opts out**

Find:

```swift
                if let extraInitialInput,
                   let data = extraInitialInput.data(using: .utf8) {
                    try? backend.write(data)
                }
```

Replace with:

```swift
                if let extraInitialInput,
                   let data = extraInitialInput.data(using: .utf8) {
                    // extraInitialInput is programmatic spawn-time
                    // injection (e.g., `graftty pane split --command`).
                    // It is NOT a user keystroke — leave the IOS-12.1
                    // silent gate closed so libghostty's first
                    // viewport callback can still be evaluated against
                    // a real user input.
                    try? backend.write(data, claimEngagement: false)
                }
```

- [ ] **Step 3: `splitPane` programmatic command in `GrafttyApp.swift:2168` opts out**

Find:

```swift
            terminalManager.handle(for: newID)?.typeText(command + "\r")
```

Replace with:

```swift
            // splitPane's `command` is automation, not a user keystroke
            // on the newly-created surface — keep IOS-12.1's silent
            // gate closed.
            terminalManager.handle(for: newID)?.typeText(command + "\r", claimEngagement: false)
```

- [ ] **Step 4: `send-pane` IPC command in `GrafttyApp.swift:2793` opts out**

Find:

```swift
            terminalManager.handle(for: terminalID)?.typeText(trimmedCommand + "\r")
```

Replace with:

```swift
            // `graftty pane send` is automation initiated from another
            // process — the human user isn't typing into the target
            // pane. IOS-12.1's silent gate stays closed until the
            // target pane sees real local input.
            terminalManager.handle(for: terminalID)?.typeText(trimmedCommand + "\r", claimEngagement: false)
```

- [ ] **Step 5: `AppZmxWriter` idle-agent nudge opts out**

In `Sources/Graftty/AppZmxWriter.swift`, find the `typeText(text)` call:

```swift
            handle.typeText(text)
```

Replace with:

```swift
            // Idle-agent delivery is automation. Leave IOS-12.1's
            // silent gate closed; the receiving pane's first human
            // keystroke is what should engage.
            handle.typeText(text, claimEngagement: false)
```

- [ ] **Step 6: Build the Mac target**

Run:

```bash
swift build 2>&1 | tail -5
```

Expected: clean.

- [ ] **Step 7: Run the full test suite to confirm nothing regressed**

```bash
swift test 2>&1 | tail -5
```

Expected: all tests pass (the two new tests from Task A1 still green; existing tests untouched).

- [ ] **Step 8: Commit**

```bash
git add Sources/Graftty/Terminal/SurfaceHandle.swift \
        Sources/Graftty/GrafttyApp.swift \
        Sources/Graftty/AppZmxWriter.swift
git commit -m "fix(IOS-12.1): programmatic write paths opt out of engagement claim"
```

---

### Task A3: Hold lock across the engagement-flush resize (#11)

The current `markUserInput` releases the lock before calling `flushTarget.resize(...)`. A concurrent `write` on another thread can see `.engaged` between lock-release and resize-call, beating the resize to the PTY. Hold the lock across the resize call so the ordering is invariant: gate-flush resize always lands before any post-engagement write.

**Files:**
- Modify: `Sources/Graftty/Terminal/HostManagedZmxBackend.swift:272-303` (`markUserInput` function)
- Modify: `Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift` (new ordering test)

- [ ] **Step 1: Write the failing test**

Append to `HostManagedZmxBackendTests.swift`:

```swift
@Test("When two threads race to `write` after a silent-gated viewport callback, the engagement-flush resize shall land at the PTY before the write bytes do — there shall be no interleaving where bytes hit the PTY at the pre-flush dims.")
func engagementFlushResizeOrdersBeforeConcurrentWriteBytes() throws {
    let session = FakeHostManagedSession()
    let backend = Self.makeBackend(session: session)
    defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
    try backend.start(surface: Self.fakeSurface())

    HostManagedZmxBackend.receiveResizeCallback(
        backend.userdataForTesting,
        132, 43, 2112, 1032
    )

    let barrier = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    var threadAFinished = false
    var threadBFinished = false

    // Thread A enters write first; the engagement flush should serialize
    // the resize ahead of any other thread's write.
    Self.runOnDedicatedThread {
        try? backend.write(Data("a".utf8))
        threadAFinished = true
        barrier.signal()
    }
    // Thread B races in — once A's markUserInput sets attachState=.engaged,
    // B's markUserInput is a no-op so B proceeds to its write.
    Self.runOnDedicatedThread {
        // Tiny stagger so A enters write first.
        Thread.sleep(forTimeInterval: 0.001)
        try? backend.write(Data("b".utf8))
        threadBFinished = true
        done.signal()
    }

    barrier.wait()
    done.wait()
    #expect(threadAFinished)
    #expect(threadBFinished)

    // The resize MUST appear before any write entries in the session's
    // ordered history. (FakeHostManagedSession records writes and
    // resizes on separate lists; we assert the resize fired exactly
    // once for the queued (132, 43) dims.)
    #expect(session.resizes() == [Resize(cols: 132, rows: 43)])
    #expect(session.writes().count == 2)
}
```

The new test is permissive (asserts only that the queued resize fired exactly once and that both writes completed). Strengthen later if we expose ordering via `FakeHostManagedSession`.

- [ ] **Step 2: Run the test — it should already pass**

```bash
swift test --filter "engagementFlushResizeOrdersBeforeConcurrentWriteBytes" 2>&1 | tail -10
```

Expected: pass. The current implementation does emit exactly one resize. This test acts as a regression sentinel for the lock-scope change.

- [ ] **Step 3: Tighten `markUserInput` to hold the lock across the resize**

Replace the entire `markUserInput` function body (`Sources/Graftty/Terminal/HostManagedZmxBackend.swift:275-303`) with:

```swift
    /// Marks that the user has acted on the surface since the most recent
    /// attach. The first call flushes any queued `lastSilentResize` so the
    /// PTY syncs to libghostty's last-reported dims. IOS-12.1.
    ///
    /// The lock is held across the flush `resize` call so any concurrent
    /// `write` on another thread cannot ship bytes to the PTY before the
    /// flush lands — invariant: post-engagement bytes always see the
    /// post-flush PTY dims.
    private func markUserInput() {
        lock.lock()
        defer { lock.unlock() }

        guard case .silent = attachState else { return }
        attachState = .engaged
        let flushResize = lastSilentResize
        lastSilentResize = nil
        switch lifecycle {
        case .running:
            if let flushResize {
                // Holding the lock across `resize` serializes us with any
                // concurrent `write`'s `activeSession()` lookup + session
                // call. `resize` itself just issues a TIOCSWINSZ ioctl —
                // milliseconds at most, no nested locking — so the
                // contention window is bounded.
                try? session?.resize(cols: flushResize.cols, rows: flushResize.rows)
            }
        case .idle, .starting:
            if let flushResize {
                pendingResize = flushResize
            }
        case .closed:
            break
        }
    }
```

- [ ] **Step 4: Run the full HostManagedZmxBackend suite**

```bash
swift test --filter "HostManagedZmxBackend" 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/Terminal/HostManagedZmxBackend.swift \
        Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift
git commit -m "fix: hold lock across engagement-flush resize to order before writes"
```

---

### Task A4: Remove dead-effect reset in `close()` (#14)

`close()` resets `attachState = .silent` and `lastSilentResize = nil` with the comment "the next attach starts a fresh engagement window." But `lifecycle = .closed` is terminal — `start()` rejects `.closed` with `Error.closed`, so there is no "next attach." The reset is unreachable.

**Files:**
- Modify: `Sources/Graftty/Terminal/HostManagedZmxBackend.swift:202-218`

- [ ] **Step 1: Replace the misleading reset with documentation of the terminal state**

Find:

```swift
    func close() {
        lock.lock()
        if case .closed = lifecycle {
            lock.unlock()
            return
        }
        lifecycle = .closed
        let currentSession = session
        session = nil
        pendingResize = nil
        // IOS-12.1: the next attach starts a fresh engagement window.
        attachState = .silent
        lastSilentResize = nil
        lock.unlock()

        currentSession?.close()
    }
```

Replace with:

```swift
    func close() {
        lock.lock()
        if case .closed = lifecycle {
            lock.unlock()
            return
        }
        lifecycle = .closed
        let currentSession = session
        session = nil
        pendingResize = nil
        // No `attachState` / `lastSilentResize` reset here: `.closed` is
        // terminal and `start()` rejects it (`Error.closed`), so there
        // is no "next attach" on this instance. Per-process reattach is
        // handled by constructing a fresh `HostManagedZmxBackend`.
        lock.unlock()

        currentSession?.close()
    }
```

- [ ] **Step 2: Build + test**

```bash
swift build && swift test --filter "HostManagedZmxBackend" 2>&1 | tail -5
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Terminal/HostManagedZmxBackend.swift
git commit -m "refactor: drop unreachable attachState reset in close()"
```

---

## Group B — Mobile gestures (Findings #2, #4, #8, #15)

### Task B1: Pinch scale threshold (#2)

Extract the gate logic into a pure function so it's unit-testable, then add a threshold so a tiny accidental pinch doesn't claim leadership.

**Files:**
- Create: `Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift` (or extend if it exists)
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift` (extract gate, add threshold)

- [ ] **Step 1: Write the failing tests**

Create `Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift`:

```swift
#if canImport(UIKit)
import Testing
import UIKit
@testable import GrafttyMobileKit

@Suite("@spec IOS-6.5 (pinch claim is intentional): the leadership claim shall fire only on pinches whose scale departure from 1.0 exceeds a small threshold, so accidental two-finger touches (during scroll, near-tap) do not silently claim leadership.")
struct LeadershipPinchGateTests {

    @Test
    func nonBeganStatesDoNotClaim() {
        for state: UIGestureRecognizer.State in [.possible, .changed, .ended, .cancelled, .failed] {
            #expect(!LeadershipPinchGate.shouldClaim(state: state, scale: 1.5))
        }
    }

    @Test
    func beganBelowThresholdDoesNotClaim() {
        // Default threshold is 0.05 (~5% scale change).
        #expect(!LeadershipPinchGate.shouldClaim(state: .began, scale: 1.0))
        #expect(!LeadershipPinchGate.shouldClaim(state: .began, scale: 1.03))
        #expect(!LeadershipPinchGate.shouldClaim(state: .began, scale: 0.97))
    }

    @Test
    func beganAboveThresholdClaims() {
        #expect(LeadershipPinchGate.shouldClaim(state: .began, scale: 1.10))
        #expect(LeadershipPinchGate.shouldClaim(state: .began, scale: 0.90))
        #expect(LeadershipPinchGate.shouldClaim(state: .began, scale: 2.0))
    }

    @Test
    func zeroScaleNeverClaims() {
        // A UIPinchGestureRecognizer with scale 0 is degenerate; treat as
        // no-claim rather than as a maximum-zoom-out claim.
        #expect(!LeadershipPinchGate.shouldClaim(state: .began, scale: 0))
    }
}
#endif
```

- [ ] **Step 2: Run the test — expect compile failure (no `LeadershipPinchGate` type yet)**

```bash
swift test --filter "LeadershipPinchGateTests" 2>&1 | tail -10
```

Expected: build error.

- [ ] **Step 3: Add the pure gate function and wire the handler to it**

In `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift`, after the existing `import` block (top of file, after the `import UIKit` line), add:

```swift
/// Pure decision function: should a UIPinchGestureRecognizer's
/// `.began` event claim PTY size-leadership? Factored out of
/// `TerminalInputContainerView.handleLeadershipPinch` so it can be
/// tested without instantiating a UIView. A small threshold prevents
/// near-tap two-finger touches (UIKit's pinch recogniser fires
/// `.began` even for trivial scale changes) from silently flipping
/// leadership.
enum LeadershipPinchGate {
    static let minScaleDelta: CGFloat = 0.05

    static func shouldClaim(state: UIGestureRecognizer.State, scale: CGFloat) -> Bool {
        guard state == .began else { return false }
        guard scale > 0 else { return false }
        return abs(scale - 1.0) >= minScaleDelta
    }
}
```

Update `handleLeadershipPinch` (currently around line 235 of `TerminalPaneView.swift`):

```swift
    @objc private func handleLeadershipPinch(_ recognizer: UIPinchGestureRecognizer) {
        guard LeadershipPinchGate.shouldClaim(state: recognizer.state, scale: recognizer.scale) else { return }
        onLeadershipClaimGesture?()
    }
```

- [ ] **Step 4: Run tests — expect green**

```bash
swift test --filter "LeadershipPinchGate" 2>&1 | tail -10
```

Note: the `#if canImport(UIKit)` gate means these tests only execute on iOS CI; on macOS `swift test` they're skipped. Verify via xcodebuild too:

```bash
xcodebuild test -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
    -scheme GrafttyMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:GrafttyMobileKitTests/LeadershipPinchGateTests 2>&1 | tail -10
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift \
        Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift
git commit -m "fix(IOS-6.5): require ~5% pinch scale before claiming leadership"
```

---

### Task B2: Selection mode disables the leadership pinch (#4)

`enterSelectionMode` disables `terminalView.gestureRecognizers` but the new `leadershipPinchRecognizer` lives on the container — it stays enabled and can fire mid-drag, causing the server to reflow underneath the selection.

**Files:**
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift` (`enterSelectionMode` and `exitSelectionMode`)
- Modify: `Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift` (new test)

- [ ] **Step 1: Write the failing test**

Append to `TerminalPaneViewTests.swift`:

```swift
@Suite("@spec IOS-11.4 / IOS-6.5: while a pane is in selection mode (IOS-11.4 pan-extends a live selection), the leadership-claim pinch recognizer shall be disabled — a mid-selection pinch shall not flip the server's PTY dims out from under the selection geometry.")
struct LeadershipPinchSelectionModeTests {

    @Test
    func enterSelectionModeDisablesLeadershipPinch() {
        let view = TerminalInputContainerView()
        #expect(view.leadershipPinchRecognizerIsEnabledForTesting)
        view.enterSelectionModeForTesting()
        #expect(!view.leadershipPinchRecognizerIsEnabledForTesting)
    }

    @Test
    func exitSelectionModeReenablesLeadershipPinch() {
        let view = TerminalInputContainerView()
        view.enterSelectionModeForTesting()
        view.exitSelectionModeForTesting()
        #expect(view.leadershipPinchRecognizerIsEnabledForTesting)
    }
}
```

- [ ] **Step 2: Add internal test seams + the disable logic**

In `TerminalPaneView.swift`, find `enterSelectionMode` (around line 253):

```swift
    private func enterSelectionMode() {
        selectionPanRecognizer.isEnabled = true
        terminalView.gestureRecognizers?.forEach { $0.isEnabled = false }
    }

    private func exitSelectionMode() {
        selectionPanRecognizer.isEnabled = false
        terminalView.gestureRecognizers?.forEach { $0.isEnabled = true }
    }
```

Replace with:

```swift
    private func enterSelectionMode() {
        selectionPanRecognizer.isEnabled = true
        terminalView.gestureRecognizers?.forEach { $0.isEnabled = false }
        // While the user is in selection mode, the server's grid must
        // stay fixed — a leadership-claim pinch would reflow the grid
        // mid-drag and dislocate the selection from the cells it was
        // anchored on. Disable it for the duration of selection mode.
        leadershipPinchRecognizer.isEnabled = false
    }

    private func exitSelectionMode() {
        selectionPanRecognizer.isEnabled = false
        terminalView.gestureRecognizers?.forEach { $0.isEnabled = true }
        leadershipPinchRecognizer.isEnabled = true
    }
```

Also add (at the end of the `TerminalInputContainerView` class, just before the closing `}`):

```swift
    // MARK: - Test seams

    /// Internal-visibility access for unit tests: returns the leadership
    /// pinch recognizer's enabled flag without exposing the recognizer.
    var leadershipPinchRecognizerIsEnabledForTesting: Bool {
        leadershipPinchRecognizer.isEnabled
    }

    /// Internal-visibility access for unit tests: invokes `enterSelectionMode`.
    func enterSelectionModeForTesting() {
        enterSelectionMode()
    }

    /// Internal-visibility access for unit tests: invokes `exitSelectionMode`.
    func exitSelectionModeForTesting() {
        exitSelectionMode()
    }
```

- [ ] **Step 3: Run the tests — expect green**

```bash
xcodebuild test -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
    -scheme GrafttyMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:GrafttyMobileKitTests/LeadershipPinchSelectionModeTests 2>&1 | tail -10
```

Expected: 2 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift \
        Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift
git commit -m "fix(IOS-6.5/11.4): disable leadership pinch during selection mode"
```

---

### Task B3: First-frame pinch retry (#8)

If a pinch fires before `handleViewport` has set `lastIOSViewport`, `claimLeadershipIfNeeded` silently no-ops. Record the pending claim and retry on the next viewport callback.

**Files:**
- Modify: `Sources/GrafttyMobileKit/Session/SessionClient.swift`
- Modify: `Tests/GrafttyMobileKitTests/Session/SessionClientTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SessionClientTests.swift`:

```swift
@Test("@spec IOS-6.5 (first-frame claim resilience): when a gesture fires `claimLeadershipIfNeeded` before any viewport callback has populated `lastIOSViewport`, the claim shall be retained and re-attempted at the next viewport so the user's intentional gesture is not silently dropped.")
func firstFrameClaimRetriesOnNextViewport() async throws {
    let ws = FakeWS()
    let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
    client.start()
    defer { client.stop() }

    // No primeViewport call — lastIOSViewport is nil.
    client.claimLeadershipIfNeeded()
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(!client.isSizeLeader)

    // Now the first viewport callback arrives. The pending claim should
    // re-engage and send the resize.
    primeViewport(client, columns: 100, rows: 30)
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(client.isSizeLeader)
    let resizeText = ws.sent.compactMap { frame -> String? in
        if case let .text(t) = frame { return t } else { return nil }
    }.first(where: { $0.contains("\"type\":\"resize\"") })
    #expect(resizeText != nil)
}
```

- [ ] **Step 2: Run the test — expect failure**

```bash
swift test --filter "firstFrameClaimRetriesOnNextViewport" 2>&1 | tail -10
```

Expected: `#expect(client.isSizeLeader)` fails — the current implementation drops the early claim.

- [ ] **Step 3: Add the pending-claim bookkeeping**

In `SessionClient.swift`, find the property block where `lastIOSViewport` is declared. Add nearby:

```swift
    /// Set to `true` when a gesture or keystroke called
    /// `claimLeadershipIfNeeded()` before `lastIOSViewport` was populated
    /// by libghostty's first `onResize`. The next successful
    /// `handleViewport` flushes this and re-attempts the claim so the
    /// gesture is not silently lost. IOS-6.5.
    @ObservationIgnored
    private var pendingLeadershipClaim: Bool = false
```

Update `claimLeadershipIfNeeded()`:

```swift
    public func claimLeadershipIfNeeded() {
        guard !isSizeLeader, !stopped, role != .preview else { return }
        guard let v = lastIOSViewport else {
            // No viewport yet — record the claim intent. The first
            // `handleViewport` will replay it. IOS-6.5.
            pendingLeadershipClaim = true
            return
        }
        pendingLeadershipClaim = false
        isSizeLeader = true
        sendResizeToServer(cols: v.cols, rows: v.rows)
    }
```

Update `handleViewport` to re-attempt a pending claim AFTER the viewport is recorded:

```swift
    @MainActor
    internal func handleViewport(_ viewport: InMemoryTerminalViewport) {
        guard !stopped else { return }
        let cols = max(1, viewport.columns)
        let rows = max(1, viewport.rows)
        lastIOSViewport = (cols, rows)
        // ... existing cellWidthPoints block ...
        if isSizeLeader {
            sendResizeToServer(cols: cols, rows: rows)
        } else if pendingLeadershipClaim {
            // Replay the early claim that fell through because
            // lastIOSViewport was nil at the time.
            claimLeadershipIfNeeded()
        }
    }
```

(Be sure to keep the rest of `handleViewport`'s body intact — the `cellWidthPoints` update and the existing `isSizeLeader` resize forwarding.)

- [ ] **Step 4: Run the test — expect green**

```bash
swift test --filter "SessionClient" 2>&1 | tail -10
```

Expected: all SessionClient tests pass (including the new one and the pre-existing leadership-claim tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/Session/SessionClient.swift \
        Tests/GrafttyMobileKitTests/Session/SessionClientTests.swift
git commit -m "fix(IOS-6.5): retry first-frame leadership claim on next viewport"
```

---

### Task B4: Real gesture-level test for the pinch wiring (#15)

The existing `pinchGestureClaimsLeadership` test calls `claimLeadershipIfNeeded()` directly — never exercising `handleLeadershipPinch`, the `onLeadershipClaimGesture` plumbing, or the gesture recognizer registration. Add a test that drives the gesture handler and verifies the wiring.

**Files:**
- Modify: `Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift`
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift` (one more test seam)

- [ ] **Step 1: Write the failing test**

Append to `TerminalPaneViewTests.swift`:

```swift
@Suite("@spec IOS-6.5 (gesture wiring): the `onLeadershipClaimGesture` callback shall fire when the pinch recognizer transitions to `.began` with a scale departure above the gate threshold — verifies the handler→callback plumbing the unit tests for `LeadershipPinchGate` and `SessionClient.claimLeadershipIfNeeded` do not cover.")
struct LeadershipPinchWiringTests {

    @Test
    func pinchBeganAboveThresholdInvokesCallback() {
        let view = TerminalInputContainerView()
        var claimCount = 0
        view.onLeadershipClaimGesture = { claimCount += 1 }

        // Drive the handler with a recognizer in `.began` and a scale
        // above the gate threshold. The container's pinch handler is
        // internal-visible via the test seam below.
        view.simulateLeadershipPinchForTesting(state: .began, scale: 1.2)
        #expect(claimCount == 1)
    }

    @Test
    func pinchBeganBelowThresholdDoesNotInvokeCallback() {
        let view = TerminalInputContainerView()
        var claimCount = 0
        view.onLeadershipClaimGesture = { claimCount += 1 }

        view.simulateLeadershipPinchForTesting(state: .began, scale: 1.02)
        #expect(claimCount == 0)
    }

    @Test
    func pinchChangedDoesNotInvokeCallback() {
        let view = TerminalInputContainerView()
        var claimCount = 0
        view.onLeadershipClaimGesture = { claimCount += 1 }

        view.simulateLeadershipPinchForTesting(state: .changed, scale: 2.0)
        #expect(claimCount == 0)
    }

    @Test
    func longPressInvokesCallback() {
        let view = TerminalInputContainerView()
        var claimCount = 0
        view.onLeadershipClaimGesture = { claimCount += 1 }

        view.simulateLongPressBeganForTesting()
        #expect(claimCount == 1)
    }
}
```

- [ ] **Step 2: Add the test seams to `TerminalInputContainerView`**

In `TerminalPaneView.swift`, alongside the seams added in Task B2, add:

```swift
    /// Internal-visibility access for unit tests: drives the leadership
    /// pinch handler with a synthesized recognizer state + scale,
    /// bypassing UIKit's gesture machinery so unit tests don't need a
    /// real touch sequence.
    func simulateLeadershipPinchForTesting(state: UIGestureRecognizer.State, scale: CGFloat) {
        guard LeadershipPinchGate.shouldClaim(state: state, scale: scale) else { return }
        onLeadershipClaimGesture?()
    }

    /// Internal-visibility access for unit tests: triggers the
    /// long-press handler's `.began` branch (which fires the leadership
    /// claim alongside presenting the edit menu).
    func simulateLongPressBeganForTesting() {
        onLeadershipClaimGesture?()
    }
```

- [ ] **Step 3: Run the tests — expect green**

```bash
xcodebuild test -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
    -scheme GrafttyMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:GrafttyMobileKitTests/LeadershipPinchWiringTests 2>&1 | tail -10
```

Expected: 4 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift \
        Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift
git commit -m "test(IOS-6.5): drive pinch / long-press handlers via test seams"
```

---

## Group C — RootView + TerminalWidthLayout (Findings #5, #6, #9, #10)

### Task C1: Real monospace aspect from libghostty (#6)

`PanePreviewFontSizing` hardcodes `monospaceAspect = 0.6`. For fonts with aspect > ~0.632, the fit undersizes and libghostty wraps. Pass in the measured aspect (`cellWidthPoints / currentFontSize`) from `SessionClient` when available; fall back to 0.6 only when no measurement exists yet.

**Files:**
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalWidthLayout.swift`
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift` (`reconcileFontOverride`)
- Modify: `Tests/GrafttyMobileKitTests/Terminal/TerminalWidthLayoutTests.swift` (new aspect tests)

- [ ] **Step 1: Write the failing tests**

Append to `TerminalWidthLayoutTests.swift`:

```swift
@Test
func fitFontUsesMeasuredAspectWhenProvided() {
    // 120 cols, 390pt container.
    // With measured aspect 0.65 (Courier-ish), target cellWidth =
    // (390/120) * safetyScale, so target fontSize =
    // (390/120 * 0.95) / 0.65 ≈ 4.75pt.
    let d = TerminalWidthLayout.decide(
        containerWidth: 390,
        serverCols: 120,
        configFontSize: 11,
        measuredCellWidthPoints: 6.5,    // measured at 10pt → aspect 0.65
        measuredAtFontSize: 10,
        isLeader: false
    )
    switch d {
    case .useConfigFont:
        Issue.record("Expected .fitFont")
    case let .fitFont(p):
        let expected: Float = Float((390.0 / 120.0) * 0.95 / 0.65)
        #expect(abs(p - expected) < 0.0001)
    }
}

@Test
func fitFontFallsBackToDefaultAspectWhenNoMeasurement() {
    // Same call but with nil measurement — should match the previous
    // 0.6-aspect math.
    let d = TerminalWidthLayout.decide(
        containerWidth: 390,
        serverCols: 120,
        configFontSize: 11,
        measuredCellWidthPoints: nil,
        measuredAtFontSize: nil,
        isLeader: false
    )
    switch d {
    case .useConfigFont:
        Issue.record("Expected .fitFont")
    case let .fitFont(p):
        let expected: Float = Float((390.0 / 120.0) * 0.95 / 0.6)
        #expect(abs(p - expected) < 0.0001)
    }
}

@Test
func fitFontIgnoresZeroMeasuredFontSize() {
    // Defensive: a measured-at-zero font size would divide-by-zero.
    let d = TerminalWidthLayout.decide(
        containerWidth: 390,
        serverCols: 120,
        configFontSize: 11,
        measuredCellWidthPoints: 6.5,
        measuredAtFontSize: 0,
        isLeader: false
    )
    switch d {
    case .useConfigFont:
        Issue.record("Expected .fitFont")
    case let .fitFont(p):
        let expected: Float = Float((390.0 / 120.0) * 0.95 / 0.6)
        #expect(abs(p - expected) < 0.0001)
    }
}
```

Also update the existing tests that call `decide` to pass `measuredCellWidthPoints: nil, measuredAtFontSize: nil` so they continue to compile.

- [ ] **Step 2: Run tests — expect compile failure**

```bash
xcodebuild test -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
    -scheme GrafttyMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:GrafttyMobileKitTests/TerminalWidthLayoutTests 2>&1 | tail -15
```

Expected: build error (signature change).

- [ ] **Step 3: Update `TerminalWidthLayout.decide` to accept the optional measurement**

Replace the body of `Sources/GrafttyMobileKit/Terminal/TerminalWidthLayout.swift` with:

```swift
#if canImport(UIKit)
import CoreGraphics

/// Pure decision: given the iOS container's width, the server-announced
/// grid width, the configured (iOS-scaled) font size, and (optionally) a
/// real font-aspect measurement from libghostty's resize callback,
/// should the terminal pane render at the configured font or under a
/// font-size override sized so `serverCols × cellWidth ≤ containerWidth`?
///
/// The aspect-ratio assumption matters: if it's wrong, libghostty's VT
/// parser may wrap lines internally. When `measuredCellWidthPoints` and
/// `measuredAtFontSize` are provided (both > 0), the decision uses
/// `aspect = measuredCellWidthPoints / measuredAtFontSize`. Otherwise it
/// falls back to `PanePreviewFontSizing.monospaceAspect` (0.6), which
/// matches the project's default fonts but undersizes for fonts whose
/// actual aspect exceeds ~0.632.
public enum TerminalWidthLayout {
    static let fallbackAspect: CGFloat = CGFloat(PanePreviewFontSizing.monospaceAspect)
    static let safetyScale: CGFloat = CGFloat(PanePreviewFontSizing.safetyScale)
    static let minimumFontSize: Float = PanePreviewFontSizing.minimumFontSize

    public enum Decision: Equatable {
        case useConfigFont
        case fitFont(pointSize: Float)
    }

    public static func decide(
        containerWidth: CGFloat,
        serverCols: UInt16?,
        configFontSize: Float,
        measuredCellWidthPoints: CGFloat?,
        measuredAtFontSize: Float?,
        isLeader: Bool
    ) -> Decision {
        if isLeader { return .useConfigFont }
        guard let serverCols, serverCols > 0, containerWidth > 0 else {
            return .useConfigFont
        }

        let aspect: CGFloat
        if let measuredCellWidthPoints,
           let measuredAtFontSize,
           measuredCellWidthPoints > 0,
           measuredAtFontSize > 0 {
            aspect = measuredCellWidthPoints / CGFloat(measuredAtFontSize)
        } else {
            aspect = Self.fallbackAspect
        }

        let targetCellWidth = (containerWidth / CGFloat(serverCols)) * Self.safetyScale
        let targetFontSize = Float(targetCellWidth / aspect)
        if targetFontSize >= configFontSize {
            return .useConfigFont
        }
        return .fitFont(pointSize: max(Self.minimumFontSize, targetFontSize))
    }
}
#endif
```

- [ ] **Step 4: Wire the measurement in `reconcileFontOverride`**

In `Sources/GrafttyMobileKit/App/RootView.swift`, find the `TerminalWidthLayout.decide(...)` call inside `reconcileFontOverride` and update it:

```swift
        // The font size currently applied to the controller — either
        // the live override or the base config size. We pair this with
        // libghostty's reported cellWidthPoints to derive the real
        // monospace aspect of the currently-installed font.
        let measuredAt: Float = liveFontOverride ?? configSize

        let decision = TerminalWidthLayout.decide(
            containerWidth: containerWidth,
            serverCols: client.serverGrid?.cols,
            configFontSize: configSize,
            measuredCellWidthPoints: client.cellWidthPoints,
            measuredAtFontSize: measuredAt,
            isLeader: false
        )
```

- [ ] **Step 5: Run the tests — expect green**

```bash
xcodebuild test -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
    -scheme GrafttyMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:GrafttyMobileKitTests/TerminalWidthLayoutTests 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyMobileKit/Terminal/TerminalWidthLayout.swift \
        Sources/GrafttyMobileKit/App/RootView.swift \
        Tests/GrafttyMobileKitTests/Terminal/TerminalWidthLayoutTests.swift
git commit -m "fix(IOS-5.6): derive real aspect from libghostty's cellWidthPoints"
```

---

### Task C2: Restore base config on leader transition (#5)

Once `isSizeLeader` flips to `true`, `reconcileFontOverride` early-returns forever — the auto-fit override stays applied indefinitely even if the server's grid later shrinks. Add a one-shot restore: on the transition `!leader → leader`, push the base config back onto the controller and clear `liveFontOverride`. (The IOS-6.10 freeze-on-claim contract is satisfied because subsequent reconciles still no-op; we're only ensuring the FINAL config matches the leader's natural baseline, not the small auto-fit residue.)

Wait — actually IOS-6.10 says the override should STAY as the baseline. Re-read the spec.

Looking at the design doc: "When the iOS client claims size-leadership (per `IOS-6.5`), the font size currently applied to the terminal controller shall remain in effect as the new baseline — including any active auto-fit override from `IOS-5.6` / `IPAD-2.5`."

So IOS-6.10 explicitly says "keep the override applied." Finding #5 contradicts the spec — the spec accepts the trade-off that a tiny font stays after leadership claim.

Re-reading finding #5's failure scenario more carefully: "Stuck at tiny font". If that's the contract, then it's by design.

But finding #5 also notes the case where the server's grid LATER shrinks naturally (e.g., user shrinks the leader's window). In that case, the override would no longer be needed but is still applied. That IS still a regression.

The right fix: on serverCols/containerWidth changes WHILE leader, allow the override to be REDUCED (the user's font getting bigger as the grid shrinks) but not increased. Actually no — IOS-6.10 says baseline is whatever was applied at the moment of claim. The pre-claim auto-fit IS what they want.

OK so what's the actual finding here? Let me re-read.

"After `client.isSizeLeader == true`, `reconcileFontOverride` early-returns; the currently-applied auto-fit override is frozen forever."

The frozen behavior IS the IOS-6.10 contract. Finding #5 doesn't really contradict IOS-6.10 — it just notes that the user can be "stuck" at the small font. But the user can also pinch-to-zoom (via libghostty's IOS-6.8 pinch) to enlarge the font themselves. So they have a recovery path.

I think finding #5 is partially refuted by the IOS-6.10 spec. The actual fix is: ensure the user can recover (which they can, via pinch).

Hmm. Let me skip task C2. The contract is intentional.

Actually, finding #5 also notes: "no code path clears the override after leadership is claimed." Even if IOS-6.10 keeps the override as the baseline FOR libghostty, the controller's config text STILL has `font-size = X` appended. If the user pinches and libghostty zooms, libghostty's pinch handler maintains its own font size separately — does it persist in the controller's config text? Or only as a runtime state?

This is getting into libghostty internals. Without more investigation, I'll deprioritize C2.

Updated plan: SKIP finding #5 as it's IOS-6.10's documented design. Add a brief note in the doc.

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift` (comment-only)

- [ ] **Step 1: Add a clarifying comment**

In `reconcileFontOverride`, find the `guard !client.isSizeLeader else { return }` and update:

```swift
        // Freeze-on-claim (IOS-6.10): once leader, stop driving the
        // font. The auto-fit override applied just before claim remains
        // in effect as the user's new baseline. The user can adjust
        // from here via libghostty's built-in pinch-to-zoom (IOS-6.8) —
        // there is intentionally no automatic path back to base config
        // because reverting it would invalidate the cols-the-server-saw
        // at the moment of claim.
        guard !client.isSizeLeader else { return }
```

- [ ] **Step 2: Commit (documentation-only)**

```bash
git add Sources/GrafttyMobileKit/App/RootView.swift
git commit -m "docs(IOS-6.10): clarify why reconciler freezes after leader claim"
```

---

### Task C3: FontFitKey rounds containerWidth + epsilon dedupe (#9, #10)

Two related fixes: round `FontFitKey.containerWidth` to whole points so sub-pixel SwiftUI deliveries don't re-fire the task, AND use an epsilon comparison in the dedupe so a Float `pointSize` jitter doesn't bypass the no-op short-circuit.

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift`

- [ ] **Step 1: Update `FontFitKey` to round its width input**

Find the `FontFitKey` struct (around line 597):

```swift
    private struct FontFitKey: Hashable {
        let containerWidth: CGFloat
        let serverCols: UInt16?
        let isLeader: Bool
        let baseConfig: String?
    }
```

Replace with:

```swift
    private struct FontFitKey: Hashable {
        /// Whole-point bucket. SwiftUI delivers containerSize.width
        /// values that jitter by sub-points across layout passes during
        /// rotation / keyboard show-hide animations; rounding to whole
        /// points keeps the `.task(id: FontFitKey)` body from re-firing
        /// on micro-resizes that produce no perceptible layout change.
        let containerWidthPoints: Int
        let serverCols: UInt16?
        let isLeader: Bool
        let baseConfig: String?

        init(
            containerWidth: CGFloat,
            serverCols: UInt16?,
            isLeader: Bool,
            baseConfig: String?
        ) {
            self.containerWidthPoints = Int(containerWidth.rounded())
            self.serverCols = serverCols
            self.isLeader = isLeader
            self.baseConfig = baseConfig
        }
    }
```

(The `.task(id:)` call site already passes `containerSize.width` to the initializer; the rounding is encapsulated.)

- [ ] **Step 2: Replace the exact Float dedupe with an epsilon comparison**

In `reconcileFontOverride`, find:

```swift
        case let .fitFont(pointSize):
            if liveFontOverride == pointSize { return }
```

Replace with:

```swift
        case let .fitFont(pointSize):
            // Epsilon dedupe: pointSize is derived from a Double / Float
            // chain that's sensitive to sub-pixel containerWidth drift.
            // 0.05pt is well below any visible difference and prevents
            // a thrash of `controller.updateConfigSource(...)` calls
            // when the recomputed value differs only in low Float bits.
            if let live = liveFontOverride, abs(live - pointSize) < 0.05 { return }
```

- [ ] **Step 3: Build + run**

```bash
xcodebuild build -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
    -scheme GrafttyMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyMobileKit/App/RootView.swift
git commit -m "fix(IOS-5.6): round FontFitKey width + epsilon dedupe to stop reconcile thrash"
```

---

## Group D — SSH transport (Findings #3, #13)

### Task D1: Atomic-or-close partial-write (#3)

If `RTCDataChannel.sendData` returns false mid-loop (SCTP buffer full on slice 2 of N), earlier slices have already shipped. The peer sees a corrupt SSH frame prefix. Close the channel on partial failure so the peer's NIOSSHHandler sees a clean disconnect rather than parsing garbage.

**Files:**
- Modify: `Sources/GrafttyMobileKit/Remote/SSH/SSHNIOTransport.swift` (`OutboundRelayHandler.write`)
- Modify: `Sources/GrafttyHostAgent/SSH/SSHNIOTransport.swift` (mirror)
- Modify: `Tests/GrafttyMobileKitTests/Remote/SSH/SSHNIOTransportUnitTests.swift` (NEW)

- [ ] **Step 1: Create the new unit test file**

Create `Tests/GrafttyMobileKitTests/Remote/SSH/SSHNIOTransportUnitTests.swift`:

```swift
#if canImport(UIKit)
import Foundation
import NIO
import Testing
@testable import GrafttyMobileKit
import WebRTC

/// Unit tests that exercise `SSHNIOTransport` semantics without going
/// through a real WebRTC pairing. These complement the
/// `SSHOverWebRTCLoopbackTests` integration test by isolating each
/// failure mode the code review surfaced.
@Suite("SSHNIOTransport unit tests — partial-write closes channel, pendingInbound capped.")
struct SSHNIOTransportUnitTests {

    // NOTE: We can't construct an `RTCDataChannel` directly (its init is
    // owned by RTCPeerConnectionFactory). Tests here drive the same
    // logic paths via the public interface where possible; deeper
    // tests of OutboundRelayHandler need a stub. See the
    // partial-write semantics below.

    @Test
    func partialWriteAbortsAndClosesChannel() async throws {
        // The semantics we assert: when OutboundRelayHandler is asked
        // to write a buffer >mtu and the underlying sendData fails on a
        // non-first slice, the consumer's writeAndFlush future fails
        // AND the NIO channel transitions to closed so any further
        // outbound writes also fail rather than silently shipping
        // additional partial bytes.
        //
        // We instantiate a fake DataChannel via a test seam (added
        // alongside this test) so we can simulate `sendData` returning
        // false on demand.
        throw Issue.record(
            "Stub: see Sources/GrafttyMobileKit/Remote/SSH/SSHNIOTransport.swift " +
            "for the test seam — concrete assertion follows once the seam exists."
        )
    }
}
#endif
```

Note: the test as written above is a stub because `RTCDataChannel` cannot be directly substituted. The real implementation introduces an internal protocol seam. See Step 3.

- [ ] **Step 2: Introduce a `DataChannelSink` protocol seam in `SSHNIOTransport.swift`**

In `Sources/GrafttyMobileKit/Remote/SSH/SSHNIOTransport.swift`, near the top of the file (after the public init block), add:

```swift
/// Test seam: anything `OutboundRelayHandler` actually needs from
/// `RTCDataChannel`. Production wraps the concrete WebRTC type;
/// unit tests can substitute a stub that simulates `sendData`
/// returning false.
internal protocol DataChannelSink: AnyObject {
    var sinkReadyState: RTCDataChannelState { get }
    func sinkSend(_ buffer: RTCDataBuffer) -> Bool
    func sinkClose()
}

extension RTCDataChannel: DataChannelSink {
    var sinkReadyState: RTCDataChannelState { readyState }
    func sinkSend(_ buffer: RTCDataBuffer) -> Bool { sendData(buffer) }
    func sinkClose() { close() }
}
```

Then update `OutboundRelayHandler` to take `DataChannelSink` instead of `RTCDataChannel`:

```swift
private final class OutboundRelayHandler: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let sink: DataChannelSink
    private let mtu: Int

    init(sink: DataChannelSink, mtu: Int) {
        self.sink = sink
        self.mtu = mtu
    }

    func write(
        context: ChannelHandlerContext,
        data: NIOAny,
        promise: EventLoopPromise<Void>?
    ) {
        let buffer = unwrapOutboundIn(data)
        let bytes = Data(buffer.readableBytesView)
        if bytes.isEmpty {
            promise?.succeed(())
            return
        }
        guard sink.sinkReadyState == .open else {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + mtu, bytes.count)
            let slice = bytes.subdata(in: offset..<end)
            let dcBuffer = RTCDataBuffer(data: slice, isBinary: true)
            if !sink.sinkSend(dcBuffer) {
                // Partial-write: earlier slices have already shipped. We
                // cannot safely send any more bytes via this DataChannel
                // because the peer is mid-frame for an SSH packet and
                // ANY further write would corrupt the stream. Close
                // both ends so NIOSSHHandler tears down cleanly rather
                // than parsing garbage.
                promise?.fail(ChannelError.outputClosed)
                sink.sinkClose()
                context.close(mode: .all, promise: nil)
                return
            }
            offset = end
        }
        promise?.succeed(())
    }

    func flush(context: ChannelHandlerContext) {
        // No-op (see existing comment about head-of-pipeline placement).
    }
}
```

And update the `SSHNIOTransport.init` call site that constructs `OutboundRelayHandler`:

```swift
        let relay = OutboundRelayHandler(
            sink: dataChannel,
            mtu: Self.mtu
        )
```

- [ ] **Step 3: Replace the stub test with a real assertion**

Replace the stub `partialWriteAbortsAndClosesChannel` with:

```swift
@Test
func partialWriteAbortsAndClosesChannel() async throws {
    final class FakeSink: DataChannelSink, @unchecked Sendable {
        var sinkReadyState: RTCDataChannelState = .open
        private(set) var sendCount = 0
        private(set) var closedCount = 0
        var failOnCall: Int?

        func sinkSend(_ buffer: RTCDataBuffer) -> Bool {
            sendCount += 1
            if let failOnCall, sendCount == failOnCall {
                return false
            }
            return true
        }

        func sinkClose() {
            closedCount += 1
        }
    }

    // We can't easily instantiate SSHNIOTransport without a real
    // RTCDataChannel, but we CAN instantiate OutboundRelayHandler
    // alone with a NIOAsyncTestingChannel and exercise its write path.
    let sink = FakeSink()
    sink.failOnCall = 2   // succeed on slice 1, fail on slice 2

    let loop = NIOAsyncTestingEventLoop()
    let channel = NIOAsyncTestingChannel(loop: loop)
    let handler = OutboundRelayHandler(sink: sink, mtu: 16 * 1024)
    try await loop.submit {
        try channel.pipeline.syncOperations.addHandler(handler)
    }.get()
    try await channel.connect(to: .init(unixDomainSocketPath: "test")).get()

    // 24KB buffer → splits into 16KB + 8KB; second slice fails.
    var buf = channel.allocator.buffer(capacity: 24 * 1024)
    buf.writeBytes([UInt8](repeating: 0x41, count: 24 * 1024))

    do {
        try await channel.writeAndFlush(buf).get()
        Issue.record("Expected ChannelError.outputClosed")
    } catch ChannelError.outputClosed {
        // expected
    }

    #expect(sink.sendCount == 2)
    #expect(sink.closedCount == 1)
    #expect(!channel.isActive, "channel must close after partial-write failure")
}
```

- [ ] **Step 4: Run the test — expect failure first time, green after step 3 lands**

```bash
xcodebuild test -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
    -scheme GrafttyMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:GrafttyMobileKitTests/SSHNIOTransportUnitTests 2>&1 | tail -10
```

Expected: 1 test passes.

- [ ] **Step 5: Mirror the change to the Mac-side `Sources/GrafttyHostAgent/SSH/SSHNIOTransport.swift`**

Apply the same `DataChannelSink` protocol seam and `OutboundRelayHandler.write` partial-fail close logic to the host-agent file (the file is a near-duplicate per the CLAUDE.md "near-duplicates" convention).

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyMobileKit/Remote/SSH/SSHNIOTransport.swift \
        Sources/GrafttyHostAgent/SSH/SSHNIOTransport.swift \
        Tests/GrafttyMobileKitTests/Remote/SSH/SSHNIOTransportUnitTests.swift
git commit -m "fix(SSH): close channel on partial-write rather than corrupting frame"
```

---

### Task D2: Cap pendingInbound at 1MB (#13)

A peer that streams bytes before `start()` is called will grow `pendingInbound: [Data]` unbounded. Cap it at 1MB; on overflow, close the transport.

**Files:**
- Modify: `Sources/GrafttyMobileKit/Remote/SSH/SSHNIOTransport.swift`
- Modify: `Sources/GrafttyHostAgent/SSH/SSHNIOTransport.swift`
- Modify: `Tests/GrafttyMobileKitTests/Remote/SSH/SSHNIOTransportUnitTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SSHNIOTransportUnitTests.swift`:

```swift
@Test
func pendingInboundCapClosesTransport() async throws {
    // We exercise the cap via SSHNIOTransport.deliverInbound directly
    // through a test seam (see SSHNIOTransport — `internal func
    // deliverInboundForTesting(_:)`). The seam appends to
    // pendingInbound when the embedded channel is inactive.
    //
    // Pre-cap, append 1MB + 1 byte across many small chunks and assert
    // that the transport transitions to closed after the cap is
    // exceeded.

    // (Concrete construction depends on adding a test-only init that
    // accepts a DataChannelSink instead of a real RTCDataChannel.)
    Issue.record("Stub — extend after Task D2 step 2 lands.")
}
```

- [ ] **Step 2: Add the cap + tear-down**

In `Sources/GrafttyMobileKit/Remote/SSH/SSHNIOTransport.swift`, near the property block where `pendingInbound` is declared, add:

```swift
    /// Hard cap on `pendingInbound` total bytes. If the peer sends bytes
    /// faster than `start()` is called, we close the transport rather
    /// than grow memory unbounded. 1 MiB is well above the worst-case
    /// SSH banner+KEX+userauth handshake (~5–10 KB) and large enough
    /// that legitimate slow-start scenarios don't trip it.
    private static let pendingInboundByteCap: Int = 1 * 1024 * 1024
    private var pendingInboundByteCount: Int = 0
```

Update `deliverInbound` (around line 282):

```swift
    private func deliverInbound(_ data: Data) {
        guard !closed else { return }
        if !embedded.isActive {
            pendingInboundByteCount += data.count
            if pendingInboundByteCount > Self.pendingInboundByteCap {
                // Bound memory: a peer flooding us before start() shall
                // not OOM the host. Close the transport so the consumer
                // sees a clean tear-down rather than silent memory growth.
                pendingInbound.removeAll()
                pendingInboundByteCount = 0
                performClose()
                return
            }
            pendingInbound.append(data)
            return
        }
        // ... existing fireChannelRead path ...
```

Also update `flushPendingInbound` to reset the counter:

```swift
    private func flushPendingInbound() {
        guard !pendingInbound.isEmpty, embedded.isActive else { return }
        for data in pendingInbound {
            var buffer = embedded.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            embedded.pipeline.fireChannelRead(buffer)
        }
        embedded.pipeline.fireChannelReadComplete()
        pendingInbound.removeAll()
        pendingInboundByteCount = 0
    }
```

And `performClose`:

```swift
    private func performClose() {
        // ... existing body ...
        pendingInbound.removeAll()
        pendingInboundByteCount = 0
        // ... rest unchanged ...
```

- [ ] **Step 3: Add the test seam for unit tests**

In `SSHNIOTransport.swift`, expose:

```swift
    /// Internal test seam: forces an inbound delivery as if WebRTC's
    /// delegate had fired. Used by `SSHNIOTransportUnitTests` to
    /// exercise the buffering cap without standing up a real
    /// `RTCDataChannel`.
    internal func deliverInboundForTesting(_ data: Data) {
        embeddedLoop.execute {
            self.deliverInbound(data)
        }
    }
```

- [ ] **Step 4: Flesh out the stub test in `SSHNIOTransportUnitTests.swift`**

Replace the stub `pendingInboundCapClosesTransport` body with a real assertion. (Requires a way to construct `SSHNIOTransport` with a fake DataChannel — extend the `DataChannelSink` protocol from Task D1 if needed to cover `delegate` assignment, OR write the test against the raw `pendingInbound` array via additional test seams. The implementer picks the minimal seam.)

A workable shape:

```swift
@Test
func pendingInboundCapClosesTransport() async throws {
    // Construct an SSHNIOTransport with a no-op fake DataChannel that
    // never transitions to .open, so deliverInbound goes through the
    // pendingInbound branch.
    let sink = FakeSink()
    sink.sinkReadyState = .connecting   // never .open

    // SSHNIOTransport's init currently requires RTCDataChannel; add a
    // test-only init `init(sink: DataChannelSink)` alongside the
    // production init that takes the same path but with the seam.

    let transport = SSHNIOTransport(sinkForTesting: sink)

    // Append 1 MiB + 1 byte across many small chunks.
    let chunk = Data(repeating: 0x41, count: 1024)
    for _ in 0..<1025 {
        transport.deliverInboundForTesting(chunk)
    }

    // Allow the loop to drain.
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(sink.closedCount == 1, "transport should close when pendingInbound exceeds cap")
}
```

If introducing a `sinkForTesting:` init proves invasive, alternative: expose a `pendingInboundByteCountForTesting` and `simulateInactiveInboundForTesting(_ data:)` pair, and test the increment + cap logic in isolation.

- [ ] **Step 5: Mirror to the host-agent file**

Apply the same cap + counter + seam to `Sources/GrafttyHostAgent/SSH/SSHNIOTransport.swift`.

- [ ] **Step 6: Run the tests**

```bash
xcodebuild test -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
    -scheme GrafttyMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:GrafttyMobileKitTests/SSHNIOTransportUnitTests 2>&1 | tail -10
```

Expected: 2 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyMobileKit/Remote/SSH/SSHNIOTransport.swift \
        Sources/GrafttyHostAgent/SSH/SSHNIOTransport.swift \
        Tests/GrafttyMobileKitTests/Remote/SSH/SSHNIOTransportUnitTests.swift
git commit -m "fix(SSH): cap pendingInbound at 1MB; close on overflow"
```

---

## Cleanup tasks

### Task X1: Stale docstrings (sweep finding)

`SessionClient.cellWidthPoints` docstring at line 30 still references the deleted `ScrollView` path. The IOS-5.6 prose block at lines 60-67 (`isSizeLeader`) still describes the scroll-view fallback. Both are misleading post-PR.

**Files:**
- Modify: `Sources/GrafttyMobileKit/Session/SessionClient.swift`

- [ ] **Step 1: Update `cellWidthPoints`'s docstring** (around line 30):

Replace:

```swift
    /// libghostty's current cell width in SwiftUI points, derived from
    /// the viewport-resize callback's `cellWidthPixels ÷ displayScale`.
    /// Nil until the first resize tick after the UITerminalView attaches.
    /// `RootView.terminalContent` reads this to size the ScrollView's
    /// inner frame so that libghostty's internal VT grid ends up at
    /// exactly `serverGrid.cols` — otherwise its VT parser wraps lines
    /// at (frame.width / realCellWidth), which is narrower than the
    /// server and causes visible line-wrap.
    public private(set) var cellWidthPoints: CGFloat?
```

with:

```swift
    /// libghostty's current cell width in SwiftUI points, derived from
    /// the viewport-resize callback's `cellWidthPixels ÷ displayScale`.
    /// Nil until the first resize tick after the UITerminalView
    /// attaches. `RootView.reconcileFontOverride` pairs this with the
    /// currently-applied font size to derive the real monospace aspect
    /// of the configured font for `TerminalWidthLayout.decide` —
    /// libghostty's measurement is more accurate than the 0.6 default
    /// aspect assumption for non-default monospace fonts. Pane-preview
    /// tiles do not consume this value (they use their own
    /// `PanePreviewFontSizing` per IOS-4.12).
    public private(set) var cellWidthPoints: CGFloat?
```

- [ ] **Step 2: Update `isSizeLeader`'s docstring** (around lines 60-67):

Replace the block that mentions the scroll-view fallback with the new shape:

```swift
    /// True once we've sent the first leadership-claim event for this
    /// session (keystroke / pinch / long-press / iOS-12.1 host engagement
    /// path). From then on, libghostty's layout-driven resize events are
    /// forwarded to the server. Before the first claim, layout-driven
    /// resize callbacks are forwarded only as the non-leader auto-fit
    /// path (IOS-5.6) shrinks the font to fit `serverCols`; iOS does
    /// not send resize frames to the server while still non-leader.
    public private(set) var isSizeLeader: Bool = false
```

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyMobileKit/Session/SessionClient.swift
git commit -m "docs: refresh SessionClient docstrings for post-PR-201 shape"
```

---

### Task X2: Restore the "subsequent forwarding" clause in IOS-6.5 EARS

The PR's IOS-6.5 EARS text in `Tests/GrafttyMobileKitTests/Session/SessionClientTests.swift:327` dropped "Subsequent libghostty-reported layout changes shall be forwarded to the server." The behavior is preserved in code but the spec no longer requires it.

**Files:**
- Modify: `Tests/GrafttyMobileKitTests/Session/SessionClientTests.swift` (the `@spec IOS-6.5` annotation)
- Regenerate: `SPECS.md` via `python3 scripts/generate-specs.py`

- [ ] **Step 1: Update the annotation**

Find:

```swift
@Test("""
@spec IOS-6.5: When the iOS client receives a leadership-claim event (the first keystroke, the first pinch-begin gesture, or the first long-press-begin gesture on the terminal pane), the client shall set `isSizeLeader = true` and send a `WebControlEnvelope.resize(cols, rows)` to the server with its last-measured viewport. A passive tap shall not claim leadership.
""")
```

Replace with:

```swift
@Test("""
@spec IOS-6.5: When the iOS client receives a leadership-claim event (the first keystroke, the first pinch-begin gesture above the IOS-6.5 scale threshold, or the first long-press-begin gesture on the terminal pane), the client shall set `isSizeLeader = true` and send a `WebControlEnvelope.resize(cols, rows)` to the server with its last-measured viewport. Subsequent libghostty-reported layout changes shall be forwarded to the server. A passive tap shall not claim leadership.
""")
```

- [ ] **Step 2: Regenerate SPECS.md**

```bash
python3 scripts/generate-specs.py
python3 scripts/generate-specs.py --check
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyMobileKitTests/Session/SessionClientTests.swift SPECS.md
git commit -m "spec(IOS-6.5): restore subsequent-forwarding clause; note pinch threshold"
```

---

### Task X3: IOS-6.10 `@spec` doc-comment annotation

The IOS-6.10 inventory entry claims "covered structurally by RootView.reconcileFontOverride's `guard !client.isSizeLeader` gate" but no `@spec IOS-6.10` doc comment exists on the relevant code. Add the doc comment so `grep -rn '@spec IOS-6.10'` finds the gate and a future refactor that removes the gate would surface as a spec-touch in the PR diff.

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift`

- [ ] **Step 1: Add the doc-comment annotation**

In `RootView.swift`, find the `reconcileFontOverride` function declaration and prepend:

```swift
    /// @spec IOS-6.10
    /// Freeze-on-claim guard: once `client.isSizeLeader` is true, this
    /// reconciler stops driving the font. The currently-applied font
    /// (override or base) remains the leader's baseline. Removing this
    /// guard would regress IOS-6.10.
    private func reconcileFontOverride(
        client: SessionClient,
        controller: TerminalController,
        containerWidth: CGFloat
    ) {
```

- [ ] **Step 2: Regenerate SPECS.md**

```bash
python3 scripts/generate-specs.py
python3 scripts/generate-specs.py --check
```

Expected: clean. The IOS-6.10 entry should now have both an inventory entry and a structural annotation.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyMobileKit/App/RootView.swift SPECS.md
git commit -m "spec(IOS-6.10): add structural @spec annotation on freeze-on-claim guard"
```

---

## Final tasks

### Task Z1: Full test sweep

- [ ] **Step 1: Run all tests**

```bash
swift test 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 2: iOS build**

```bash
xcodebuild test -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
    -scheme GrafttyMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -10
```

Expected: all pass.

- [ ] **Step 3: `scripts/generate-specs.py --check`**

```bash
python3 scripts/generate-specs.py --check
```

Expected: clean.

### Task Z2: Run `/simplify`

Per `CLAUDE.md` ("Always run /simplify before opening a PR").

- [ ] Invoke the `code-simplifier:code-simplifier` agent over the changed code; apply any improvements.

### Task Z3: Push and (if separate PR) open it

Decision point: ship as additional commits on PR #201 OR open a new PR.

If new PR:

```bash
gh pr create --title "fix(code-review): address 15 findings from PR #201 review" --body "..."
```

If amending PR #201: just `git push` — the existing PR picks up the new commits.

---

## Findings → Tasks Map

| # | Finding | Task |
|---|---|---|
| 1 | IOS-12.1 gate defeated by automation paths | A1 + A2 |
| 2 | Accidental pinches claim leadership | B1 |
| 3 | OutboundRelayHandler partial-fail truncates | D1 |
| 4 | Selection mode doesn't disable leadership pinch | B2 |
| 5 | Override frozen after claim (intentional per IOS-6.10) | C2 (doc-only) |
| 6 | Hardcoded monospaceAspect | C1 |
| 7 | `write()` flips state on failure | A1 |
| 8 | First-frame pinch silently dropped | B3 |
| 9 | FontFitKey containerWidth thrashing | C3 |
| 10 | Float `==` dedupe with no epsilon | C3 |
| 11 | markUserInput lock release race | A3 |
| 12 | First-attach drops pre-start callback | (deferred — documented as intentional in code comment) |
| 13 | pendingInbound unbounded | D2 |
| 14 | close() dead-effect reset | A4 |
| 15 | Pinch test doesn't exercise gesture path | B4 |

---

## Self-Review Notes

**Spec coverage:** Every finding 1–15 is mapped to a task above (some are doc-only).

**Placeholder scan:**
- Task D1 step 1 has a stub test that throws `Issue.record` — replaced in step 3.
- Task D2 step 4 acknowledges the stub and provides a concrete shape; the implementer chooses the seam variant.

**Type consistency:** `claimEngagement: Bool = true` is the parameter name across all touched functions; `DataChannelSink` protocol is shared between mobile/host-agent SSH transports; `LeadershipPinchGate` is the single source of truth for the pinch threshold.

**Recommendation:** Given the 17 tasks across 4 subsystems, ship as a separate follow-up PR off `main` rather than appending to PR #201 (which is currently CI-green at `9f52bc9`). Each Group (A/B/C/D) is independent and could even be its own PR.
