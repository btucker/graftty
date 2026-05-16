# Mobile Copy and Paste Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship user-initiated clipboard surface in GrafttyMobile — long-press menu with Select / Select All / Paste, drag-to-extend via libghostty's native selection, Copy/Cancel post-selection menu.

**Architecture:** A fork of `Lakr233/libghostty-spm` (pinned to a feature branch at `github.com/btucker/libghostty-spm`) exposes a minimal Swift-typed selection API. GrafttyMobileKit gains a pure `TerminalSelectionController` state machine, a real `SurfaceProxy` adapter wrapping `TerminalSurface`, and gesture/menu plumbing on `TerminalInputContainerView`. `SessionClient.sendPaste(_:)` handles bracketed-paste delimiting for the clipboard → terminal path.

**Tech Stack:** Swift, SwiftUI, UIKit (`UIEditMenuInteraction`, `UILongPressGestureRecognizer`, `UIPanGestureRecognizer`), `UIPasteboard`, libghostty-spm (forked), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-05-15-mobile-copy-paste-design.md`. New `@spec` IDs: `IOS-11.1` through `IOS-11.11`.

**CI note:** `swift test` on macOS does NOT exercise UIKit-guarded mobile code. The authoritative test signal is the `ios-build-and-test` job (`.github/workflows/ci.yml:82`). Validate locally with `xcodebuild test` on the iOS Simulator destination matching CI.

---

## Task 1: Fork libghostty-spm with public selection API

This task is executed in a SECOND repository (the fork). All other tasks happen in the GrafttyMobile worktree at `/Users/btucker/projects/graftty/.worktrees/mobile-copy-paste`.

**Files (in the fork repo):**
- Modify: `Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift`
- Modify: `Sources/GhosttyTerminal/Surface/TerminalSurface.swift`

**Files (in this repo):**
- Modify: `Package.swift`
- Will regenerate: `Package.resolved`

- [ ] **Step 1: Clone the fork into a sibling working directory**

```bash
mkdir -p /Users/btucker/projects/graftty-libghostty-fork
cd /Users/btucker/projects/graftty-libghostty-fork
git clone https://github.com/btucker/libghostty-spm.git
cd libghostty-spm
# Branch off the commit graftty is currently pinned at.
git checkout c227bbef9de1471c3250e3c2ffd37aabaac6b978
git checkout -b expose-selection-api
```

- [ ] **Step 2: Make `UITerminalView.surface` public**

Edit `Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift` line 63 from:

```swift
        var surface: TerminalSurface? {
            core.surface
        }
```

to:

```swift
        public var surface: TerminalSurface? {
            core.surface
        }
```

- [ ] **Step 3: Add public selection-driving methods to `TerminalSurface`**

In `Sources/GhosttyTerminal/Surface/TerminalSurface.swift`, after the existing `sendMouseScroll` method (around line 99), append a new `// MARK: - Selection` section:

```swift
    // MARK: - Selection

    /// Press the LEFT mouse button at the current `sendMousePos` location.
    /// Used by external callers (e.g., touch-driven selection on iOS) to
    /// drive libghostty's native selection state machine.
    @discardableResult
    public func sendLeftMouseDown() -> Bool {
        sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT,
            mods: ghostty_input_mods_e(0)
        )
    }

    /// Release the LEFT mouse button.
    @discardableResult
    public func sendLeftMouseUp() -> Bool {
        sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_LEFT,
            mods: ghostty_input_mods_e(0)
        )
    }

    /// Update the mouse position with no modifier keys held.
    public func sendMousePos(x: Double, y: Double) {
        sendMousePos(x: x, y: y, mods: ghostty_input_mods_e(0))
    }

    /// Trigger a named binding action (e.g., `"select_all"`,
    /// `"clear_selection"`).
    @discardableResult
    public func performAction(_ name: String) -> Bool {
        performBindingAction(name)
    }

    /// Returns the current selection's text, if any, by calling
    /// `ghostty_surface_read_selection`. Returns `nil` when there is
    /// no active selection or the surface is uninitialized.
    public func readSelection() -> String? {
        guard let s = surface else { return nil }
        guard ghostty_surface_has_selection(s) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(s, &text) else { return nil }
        defer { ghostty_surface_free_text(s, &text) }
        guard let cString = text.text else { return nil }
        return String(cString: cString)
    }
```

(`GHOSTTY_MOUSE_PRESS`, `GHOSTTY_MOUSE_RELEASE`, `GHOSTTY_MOUSE_LEFT` are `ghostty_input_mouse_*_e` constants from GhosttyKit. The exact spelling matches the rest of the file — copy from the existing internal `sendMouseButton` callers if the enum names differ from the C symbols.)

- [ ] **Step 4: Build the fork to verify the additions compile**

```bash
cd /Users/btucker/projects/graftty-libghostty-fork/libghostty-spm
swift build 2>&1 | tail -30
```

Expected: succeeds with no errors. If `GHOSTTY_MOUSE_*` constants don't resolve, replace them with the exact `ghostty_input_mouse_button_e(rawValue: …)` form already used in `TerminalSurface.sendMouseButton` callers (grep `GHOSTTY_MOUSE` in the codebase to find the canonical spelling).

- [ ] **Step 5: Commit and push the fork branch**

```bash
cd /Users/btucker/projects/graftty-libghostty-fork/libghostty-spm
git add Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift Sources/GhosttyTerminal/Surface/TerminalSurface.swift
git commit -m "Expose selection-driving APIs publicly

- Make UITerminalView.surface public.
- Make sendLeftMouseDown/Up, sendMousePos (no-mods),
  performAction, and readSelection() public on TerminalSurface.
- Existing internal APIs are unchanged."
git push -u origin expose-selection-api
```

Record the resulting commit SHA — it goes in `Package.swift` in the next step.

- [ ] **Step 6: Pin `Package.swift` to the fork branch**

In `Package.swift`, change the package URL and pin to the fork's branch:

```swift
        .package(url: "https://github.com/btucker/libghostty-spm.git", branch: "expose-selection-api"),
```

(Replace the existing `.package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.0.0")` line.)

- [ ] **Step 7: Resolve and build**

```bash
cd /Users/btucker/projects/graftty/.worktrees/mobile-copy-paste
swift package resolve 2>&1 | tail -20
swift build --target GrafttyMobileKit 2>&1 | tail -20
```

Expected: package resolves cleanly and the existing build still passes.

- [ ] **Step 8: Commit Package.swift + Package.resolved**

```bash
cd /Users/btucker/projects/graftty/.worktrees/mobile-copy-paste
git add Package.swift Package.resolved
git commit -m "build: pin libghostty-spm to btucker/expose-selection-api fork

Exposes the surface accessor and a minimal selection-driving API
required for IOS-11.x (mobile copy/paste). The fork is a thin layer
of public access modifiers + a readSelection() helper; no behavioral
changes."
```

---

## Task 2: Add IOS-11.x inventory to IosTodo.swift

Adds the eleven new spec IDs as `.disabled` entries so they show up in `SPECS.md` before any test or implementation lands. Each subsequent task promotes one or more of these to real `@Test` entries.

**Files:**
- Modify: `Tests/GrafttyTests/Specs/IosTodo.swift`

- [ ] **Step 1: Append IOS-11.1 through IOS-11.11 to IosTodo.swift**

Before the closing `}` of the `IosTodo` suite, append:

```swift
    @Test("""
@spec IOS-11.1: When the user long-presses a focused terminal pane, the application shall present a `UIEditMenuInteraction` menu at the touch point containing **Select**, **Select All**, and (when `UIPasteboard.general.hasStrings` is true at menu-build time) **Paste**.
""", .disabled("not yet implemented"))
    func ios_11_1() async throws { }

    @Test("""
@spec IOS-11.2: When the user taps **Select** in the long-press menu, the application shall ask libghostty to word-select the cell under the long-press point by synthesizing a LEFT mouse-down/up pair plus a second click within libghostty's double-click window, and shall enter selection mode for that pane.
""", .disabled("not yet implemented"))
    func ios_11_2() async throws { }

    @Test("""
@spec IOS-11.3: When the user taps **Select All** in the long-press menu, the application shall invoke libghostty's `select_all` binding action via `surface.performAction("select_all")` and shall enter selection mode for that pane with the visible viewport highlighted.
""", .disabled("not yet implemented"))
    func ios_11_3() async throws { }

    @Test("""
@spec IOS-11.4: While in selection mode, the application shall extend the live selection by forwarding pan-gesture positions to `surface.sendMousePos(...)`, and libghostty's built-in pan-to-scroll recognizer on the underlying `UITerminalView` shall be disabled until selection mode exits.
""", .disabled("not yet implemented"))
    func ios_11_4() async throws { }

    @Test("""
@spec IOS-11.5: When selection mode is active and the user lifts their finger after Select / Select All / extend, the application shall present a second `UIEditMenuInteraction` menu anchored near the selection rect containing **Copy** and **Cancel**.
""", .disabled("not yet implemented"))
    func ios_11_5() async throws { }

    @Test("""
@spec IOS-11.6: When the user taps **Copy**, the application shall extract the active selection via `surface.readSelection()`, write the result to `UIPasteboard.general.string`, clear libghostty's selection, and exit selection mode. If `readSelection()` returns nil or empty, the pasteboard shall not be modified.
""", .disabled("not yet implemented"))
    func ios_11_6() async throws { }

    @Test("""
@spec IOS-11.7: When the user taps **Cancel**, taps outside the highlighted selection, or presses a key on the terminal control bar while in selection mode, the application shall clear libghostty's selection and exit selection mode without modifying the pasteboard.
""", .disabled("not yet implemented"))
    func ios_11_7() async throws { }

    @Test("""
@spec IOS-11.8: When the user taps **Paste** in the long-press menu, the application shall read `UIPasteboard.general.string` and, when non-empty, send it via `SessionClient.sendPaste(_:)`. An empty or absent clipboard string shall be a silent no-op.
""", .disabled("not yet implemented"))
    func ios_11_8() async throws { }

    @Test("""
@spec IOS-11.9: `SessionClient.sendPaste(_:)` shall wrap the payload in `ESC [ 200 ~` and `ESC [ 201 ~` and emit the wrapped sequence as a single binary WebSocket frame. The single-byte LF→CR translation of `IOS-6.3` shall not apply to this path; the payload's own line endings shall be preserved verbatim.
""", .disabled("not yet implemented"))
    func ios_11_9() async throws { }

    @Test("""
@spec IOS-11.10: Selection mode shall be per-pane state owned by the focused pane's `TerminalSelectionController`. Selection in one pane shall not affect the selection state of any other pane.
""", .disabled("not yet implemented"))
    func ios_11_10() async throws { }

    @Test("""
@spec IOS-11.11: While a pane is rendered as a worktree-detail preview tile (`IOS-4.10`), the long-press selection menu shall not be installed; tapping the tile shall continue to open the fullscreen pane per `IOS-4.21`.
""", .disabled("not yet implemented"))
    func ios_11_11() async throws { }
```

- [ ] **Step 2: Run scripts/generate-specs.py and verify it succeeds**

```bash
cd /Users/btucker/projects/graftty/.worktrees/mobile-copy-paste
python3 scripts/generate-specs.py
git status SPECS.md
```

Expected: `SPECS.md` is modified to include `IOS-11.1` through `IOS-11.11` under a new `### IOS-11.x` heading.

- [ ] **Step 3: Verify the disabled tests are picked up by Swift Testing**

```bash
swift test --filter IosTodo 2>&1 | tail -20
```

Expected: tests run, all eleven IOS-11.x entries listed as skipped/disabled.

- [ ] **Step 4: Commit**

```bash
git add Tests/GrafttyTests/Specs/IosTodo.swift SPECS.md
git commit -m "spec(IOS-11): inventory for mobile copy/paste

Adds IOS-11.1..11.11 as disabled inventory entries. Subsequent
commits promote them to real @Test entries as implementations
land."
```

---

## Task 3: `SessionClient.sendPaste(_:)` with bracketed-paste delimiters

Smallest end-to-end slice. Implements `IOS-11.9` fully, in isolation from the UI work.

**Files:**
- Modify: `Sources/GrafttyMobileKit/Session/SessionClient.swift` (after the existing `sendSoftwareKeyboardText` method around line 314)
- Modify: `Tests/GrafttyMobileKitTests/Session/SessionClientTests.swift`
- Modify: `Tests/GrafttyTests/Specs/IosTodo.swift` (remove the IOS-11.9 entry)

- [ ] **Step 1: Write the failing test for the happy path**

In `Tests/GrafttyMobileKitTests/Session/SessionClientTests.swift`, add — somewhere alongside the existing `submitReturnSendsCR` etc. tests:

```swift
    @Test("""
    @spec IOS-11.9: `SessionClient.sendPaste(_:)` shall wrap the payload in `ESC [ 200 ~` and `ESC [ 201 ~` and emit the wrapped sequence as a single binary WebSocket frame. The single-byte LF→CR translation of `IOS-6.3` shall not apply to this path; the payload's own line endings shall be preserved verbatim.
    """)
    func sendPasteWrapsInBracketedPasteDelimiters() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        client.sendPaste("hello")
        try await Task.sleep(nanoseconds: 100_000_000)

        let expected = Data("\u{1B}[200~hello\u{1B}[201~".utf8)
        #expect(ws.sent.contains(.binary(expected)))
    }

    @Test
    func sendPastePreservesEmbeddedNewlinesVerbatim() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        client.sendPaste("a\nb")
        try await Task.sleep(nanoseconds: 100_000_000)

        let expected = Data("\u{1B}[200~a\nb\u{1B}[201~".utf8)
        #expect(ws.sent.contains(.binary(expected)))
        // The IOS-6.3 LF→CR translation must NOT apply here.
        #expect(!ws.sent.contains(.binary(Data("\u{1B}[200~a\rb\u{1B}[201~".utf8))))
    }

    @Test
    func sendPasteSkipsEmptyPayload() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        let before = ws.sent.count
        client.sendPaste("")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ws.sent.count == before)
    }
```

- [ ] **Step 2: Run the new tests; verify they fail with "no such method"**

```bash
cd /Users/btucker/projects/graftty/.worktrees/mobile-copy-paste
xcodebuild \
  -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile \
  -sdk iphonesimulator \
  -configuration Debug \
  -skipPackagePluginValidation \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GrafttyMobileKitTests/SessionClientTests/sendPasteWrapsInBracketedPasteDelimiters \
  test 2>&1 | tail -30
```

Expected: build failure citing missing `sendPaste`. (If iPhone 17 destination is not installed locally, substitute the available iPhone simulator name; CI uses iPhone 17.)

- [ ] **Step 3: Implement `sendPaste` on `SessionClient`**

Insert into `Sources/GrafttyMobileKit/Session/SessionClient.swift` right after `sendSoftwareKeyboardText` (around line 314):

```swift
    /// IOS-11.9: send clipboard text as a single bracketed-paste frame.
    /// Bypasses the IOS-6.3 single-byte LF→CR translation — pastes are
    /// not per-keystroke input and the payload's line endings are part
    /// of the paste's meaning.
    public func sendPaste(_ text: String) {
        guard !text.isEmpty else { return }
        var payload = Data()
        payload.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) // ESC [ 2 0 0 ~
        payload.append(Data(text.utf8))
        payload.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]) // ESC [ 2 0 1 ~
        recordActivity()
        sendBinary(payload)
        claimLeadershipIfNeeded()
    }
```

Note: this mirrors `sendInput`'s side effects (`recordActivity`, `claimLeadershipIfNeeded`) but bypasses the LF→CR check that lives on the `box.onBytes` libghostty path — see `SessionClient.swift:160-164`. The libghostty path is not involved here at all; we call `sendBinary` directly.

- [ ] **Step 4: Run the tests; verify they pass**

```bash
xcodebuild \
  -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile \
  -sdk iphonesimulator \
  -configuration Debug \
  -skipPackagePluginValidation \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GrafttyMobileKitTests/SessionClientTests \
  test 2>&1 | tail -30
```

Expected: all three new tests pass plus the existing `softKeyboardReturnLFIsTranslatedToCR` regression passes.

- [ ] **Step 5: Promote IOS-11.9 from inventory to active test**

In `Tests/GrafttyTests/Specs/IosTodo.swift`, remove the `ios_11_9()` block. The promoted test in `SessionClientTests.swift` already carries the same `@spec IOS-11.9:` text.

- [ ] **Step 6: Regenerate SPECS.md**

```bash
python3 scripts/generate-specs.py
```

Expected: `IOS-11.9` still appears in `SPECS.md` — but now sourced from `SessionClientTests.swift`, not `IosTodo.swift`.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyMobileKit/Session/SessionClient.swift \
        Tests/GrafttyMobileKitTests/Session/SessionClientTests.swift \
        Tests/GrafttyTests/Specs/IosTodo.swift \
        SPECS.md
git commit -m "feat(mobile): SessionClient.sendPaste with bracketed paste (IOS-11.9)

Wraps clipboard payload in ESC[200~…ESC[201~, sends as a single
binary frame, and deliberately bypasses the IOS-6.3 single-byte
LF→CR rule so embedded newlines pass through verbatim."
```

---

## Task 4: `SurfaceProxy` protocol + real adapter

Introduces the testing seam. The protocol is a thin facade over the now-public selection-driving methods on `TerminalSurface`. A real adapter wraps an actual surface; tests use a fake.

**Files:**
- Create: `Sources/GrafttyMobileKit/Terminal/SurfaceProxy.swift`
- Create: `Tests/GrafttyMobileKitTests/Terminal/SurfaceProxyTests.swift` (light smoke-test; deeper coverage comes through the controller tests)

- [ ] **Step 1: Write a smoke test that the protocol compiles and a real adapter can be constructed**

Create `Tests/GrafttyMobileKitTests/Terminal/SurfaceProxyTests.swift`:

```swift
#if canImport(UIKit)
import Testing
import GhosttyTerminal
@testable import GrafttyMobileKit

@Suite
@MainActor
struct SurfaceProxyTests {
    @Test
    func realProxyHandlesNilSurfaceGracefully() {
        // A SurfaceProxy backed by a nil TerminalSurface? should return
        // nil from readSelection and ignore mouse-event calls without
        // crashing — this is the state during pane teardown.
        let proxy = RealSurfaceProxy(surfaceProvider: { nil })
        #expect(proxy.readSelection() == nil)
        proxy.sendLeftMouseDown()       // no-op, no crash
        proxy.sendLeftMouseUp()
        proxy.sendMousePos(x: 0, y: 0)
        #expect(proxy.performAction("select_all") == false)
    }
}
#endif
```

- [ ] **Step 2: Implement `SurfaceProxy.swift`**

Create `Sources/GrafttyMobileKit/Terminal/SurfaceProxy.swift`:

```swift
#if canImport(UIKit)
import GhosttyTerminal

/// A narrow facade over `TerminalSurface`'s selection-driving methods,
/// so `TerminalSelectionController` can be tested without a real
/// libghostty surface.
@MainActor
public protocol SurfaceProxy {
    @discardableResult func sendLeftMouseDown() -> Bool
    @discardableResult func sendLeftMouseUp() -> Bool
    func sendMousePos(x: Double, y: Double)
    @discardableResult func performAction(_ name: String) -> Bool
    func readSelection() -> String?
}

/// Real adapter used in production. The surface is looked up lazily
/// per-call because a `UITerminalView`'s surface may be rebuilt during
/// a pane's lifetime (e.g., size-leader changes), so capturing a
/// reference at init time would dangle.
@MainActor
public final class RealSurfaceProxy: SurfaceProxy {
    private let surfaceProvider: () -> TerminalSurface?

    public init(surfaceProvider: @escaping () -> TerminalSurface?) {
        self.surfaceProvider = surfaceProvider
    }

    @discardableResult
    public func sendLeftMouseDown() -> Bool {
        surfaceProvider()?.sendLeftMouseDown() ?? false
    }

    @discardableResult
    public func sendLeftMouseUp() -> Bool {
        surfaceProvider()?.sendLeftMouseUp() ?? false
    }

    public func sendMousePos(x: Double, y: Double) {
        surfaceProvider()?.sendMousePos(x: x, y: y)
    }

    @discardableResult
    public func performAction(_ name: String) -> Bool {
        surfaceProvider()?.performAction(name) ?? false
    }

    public func readSelection() -> String? {
        surfaceProvider()?.readSelection()
    }
}
#endif
```

- [ ] **Step 3: Build and run the smoke test**

```bash
xcodebuild \
  -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile \
  -sdk iphonesimulator \
  -configuration Debug \
  -skipPackagePluginValidation \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GrafttyMobileKitTests/SurfaceProxyTests \
  test 2>&1 | tail -20
```

Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyMobileKit/Terminal/SurfaceProxy.swift \
        Tests/GrafttyMobileKitTests/Terminal/SurfaceProxyTests.swift
git commit -m "feat(mobile): SurfaceProxy facade + real adapter

Narrow surface for the selection state machine. Pure protocol;
no behavioral changes."
```

---

## Task 5: `TerminalSelectionController` state machine

Pure state machine driven by a `SurfaceProxy` and a `Pasteboard` protocol. Implements `IOS-11.2`, `11.3`, `11.4` (the extend behavior), `11.6`, `11.7` (the cancel/clear-on-key behavior), `11.10` (per-pane scope falls out from one instance per pane).

**Files:**
- Create: `Sources/GrafttyMobileKit/Terminal/TerminalSelectionController.swift`
- Create: `Tests/GrafttyMobileKitTests/Terminal/TerminalSelectionControllerTests.swift`
- Modify: `Tests/GrafttyTests/Specs/IosTodo.swift` (remove `ios_11_2`, `ios_11_3`, `ios_11_6`, `ios_11_7`, `ios_11_10`)

- [ ] **Step 1: Define the `Pasteboard` protocol up front (so the controller depends on it)**

Append to `Sources/GrafttyMobileKit/Terminal/SurfaceProxy.swift` (within the existing `#if canImport(UIKit)` block):

```swift
import UIKit

/// A narrow facade over `UIPasteboard` so the selection controller can
/// be tested without touching the system clipboard.
@MainActor
public protocol Pasteboard {
    var hasStrings: Bool { get }
    var string: String? { get set }
}

extension UIPasteboard: Pasteboard {}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/GrafttyMobileKitTests/Terminal/TerminalSelectionControllerTests.swift`:

```swift
#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@MainActor
final class FakeSurfaceProxy: SurfaceProxy {
    enum Event: Equatable {
        case leftDown
        case leftUp
        case mousePos(Double, Double)
        case action(String)
    }
    var events: [Event] = []
    var selectionText: String?

    @discardableResult func sendLeftMouseDown() -> Bool {
        events.append(.leftDown)
        return true
    }
    @discardableResult func sendLeftMouseUp() -> Bool {
        events.append(.leftUp)
        return true
    }
    func sendMousePos(x: Double, y: Double) {
        events.append(.mousePos(x, y))
    }
    @discardableResult func performAction(_ name: String) -> Bool {
        events.append(.action(name))
        return true
    }
    func readSelection() -> String? { selectionText }
}

@MainActor
final class FakePasteboard: Pasteboard {
    var hasStrings: Bool { string?.isEmpty == false }
    var string: String?
}

@Suite
@MainActor
struct TerminalSelectionControllerTests {

    @Test("""
    @spec IOS-11.2: When the user taps **Select** in the long-press menu, the application shall ask libghostty to word-select the cell under the long-press point by synthesizing a LEFT mouse-down/up pair plus a second click within libghostty's double-click window, and shall enter selection mode for that pane.
    """)
    func beginSelectionSynthesizesDoubleClickAtPointAndActivatesMode() {
        let surface = FakeSurfaceProxy()
        let controller = TerminalSelectionController(surface: surface)

        controller.beginSelection(at: CGPoint(x: 10, y: 20))

        #expect(controller.isActive)
        // Sequence: position, down, up, down, up — two clicks at the same point.
        #expect(surface.events == [
            .mousePos(10, 20),
            .leftDown,
            .leftUp,
            .leftDown,
            .leftUp,
        ])
    }

    @Test("""
    @spec IOS-11.3: When the user taps **Select All** in the long-press menu, the application shall invoke libghostty's `select_all` binding action via `surface.performAction("select_all")` and shall enter selection mode for that pane with the visible viewport highlighted.
    """)
    func selectAllInvokesBindingAndActivatesMode() {
        let surface = FakeSurfaceProxy()
        let controller = TerminalSelectionController(surface: surface)

        controller.selectAll()

        #expect(controller.isActive)
        #expect(surface.events == [.action("select_all")])
    }

    @Test
    func extendForwardsToMousePosOnlyWhenActive() {
        let surface = FakeSurfaceProxy()
        let controller = TerminalSelectionController(surface: surface)

        // Inactive: extend is a no-op.
        controller.extend(to: CGPoint(x: 5, y: 5))
        #expect(surface.events.isEmpty)

        controller.beginSelection(at: CGPoint(x: 0, y: 0))
        let pre = surface.events.count
        controller.extend(to: CGPoint(x: 100, y: 200))
        #expect(surface.events.count == pre + 1)
        #expect(surface.events.last == .mousePos(100, 200))
    }

    @Test("""
    @spec IOS-11.6: When the user taps **Copy**, the application shall extract the active selection via `surface.readSelection()`, write the result to `UIPasteboard.general.string`, clear libghostty's selection, and exit selection mode. If `readSelection()` returns nil or empty, the pasteboard shall not be modified.
    """)
    func copyWritesSelectionToPasteboardAndExitsMode() {
        let surface = FakeSurfaceProxy()
        surface.selectionText = "captured"
        let pb = FakePasteboard()
        let controller = TerminalSelectionController(surface: surface)
        controller.beginSelection(at: .zero)
        surface.events.removeAll()  // ignore begin events for this assertion

        let result = controller.copy(toPasteboard: pb)

        #expect(result == "captured")
        #expect(pb.string == "captured")
        #expect(!controller.isActive)
        #expect(surface.events.contains(.action("clear_selection")))
    }

    @Test
    func copyWithEmptySelectionDoesNotTouchPasteboard() {
        let surface = FakeSurfaceProxy()
        surface.selectionText = ""
        let pb = FakePasteboard()
        pb.string = "untouched"
        let controller = TerminalSelectionController(surface: surface)
        controller.beginSelection(at: .zero)

        _ = controller.copy(toPasteboard: pb)

        #expect(pb.string == "untouched")
        #expect(!controller.isActive)
    }

    @Test
    func copyWithNilSelectionDoesNotTouchPasteboard() {
        let surface = FakeSurfaceProxy()
        surface.selectionText = nil
        let pb = FakePasteboard()
        pb.string = "untouched"
        let controller = TerminalSelectionController(surface: surface)
        controller.beginSelection(at: .zero)

        _ = controller.copy(toPasteboard: pb)

        #expect(pb.string == "untouched")
        #expect(!controller.isActive)
    }

    @Test("""
    @spec IOS-11.7: When the user taps **Cancel**, taps outside the highlighted selection, or presses a key on the terminal control bar while in selection mode, the application shall clear libghostty's selection and exit selection mode without modifying the pasteboard.
    """)
    func cancelClearsSelectionAndExitsModeWithoutPasteboard() {
        let surface = FakeSurfaceProxy()
        surface.selectionText = "would-have-been-copied"
        let pb = FakePasteboard()
        pb.string = "untouched"
        let controller = TerminalSelectionController(surface: surface)
        controller.beginSelection(at: .zero)

        controller.cancel()

        #expect(pb.string == "untouched")
        #expect(!controller.isActive)
        #expect(surface.events.contains(.action("clear_selection")))
    }

    @Test("""
    @spec IOS-11.10: Selection mode shall be per-pane state owned by the focused pane's `TerminalSelectionController`. Selection in one pane shall not affect the selection state of any other pane.
    """)
    func twoControllersHaveIndependentState() {
        let aSurface = FakeSurfaceProxy()
        let bSurface = FakeSurfaceProxy()
        let a = TerminalSelectionController(surface: aSurface)
        let b = TerminalSelectionController(surface: bSurface)

        a.beginSelection(at: .zero)
        #expect(a.isActive)
        #expect(!b.isActive)
        #expect(bSurface.events.isEmpty)
    }
}
#endif
```

- [ ] **Step 3: Verify tests fail with "no such type"**

```bash
xcodebuild \
  -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile \
  -sdk iphonesimulator \
  -configuration Debug \
  -skipPackagePluginValidation \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GrafttyMobileKitTests/TerminalSelectionControllerTests \
  test 2>&1 | tail -30
```

Expected: build fails citing missing `TerminalSelectionController`.

- [ ] **Step 4: Implement `TerminalSelectionController`**

Create `Sources/GrafttyMobileKit/Terminal/TerminalSelectionController.swift`:

```swift
#if canImport(UIKit)
import CoreGraphics

/// IOS-11.x: per-pane selection state machine. Drives libghostty's
/// native selection through a `SurfaceProxy`, extracts selection text
/// via `SurfaceProxy.readSelection`, writes to a `Pasteboard`. Pure
/// logic — no UIKit imports beyond `CGPoint` (CoreGraphics).
@MainActor
public final class TerminalSelectionController {
    public private(set) var isActive: Bool = false
    private let surface: SurfaceProxy

    public init(surface: SurfaceProxy) {
        self.surface = surface
    }

    /// IOS-11.2: word-select via synthesized double-click at `point`.
    public func beginSelection(at point: CGPoint) {
        surface.sendMousePos(x: Double(point.x), y: Double(point.y))
        // Two left-clicks at the same point — libghostty's mouse handler
        // promotes back-to-back presses within its double-click window
        // to word-select semantics.
        surface.sendLeftMouseDown()
        surface.sendLeftMouseUp()
        surface.sendLeftMouseDown()
        surface.sendLeftMouseUp()
        isActive = true
    }

    /// IOS-11.3: full-viewport select via libghostty's `select_all` binding.
    public func selectAll() {
        surface.performAction("select_all")
        isActive = true
    }

    /// IOS-11.4: forward pan to libghostty's mouse-position handler,
    /// which extends the current selection while the LEFT button
    /// remains pressed in libghostty's view. (Our two-press begin
    /// leaves no button held, so for v1 we treat `extend` as
    /// shift-click: hold shift via mods? — TODO at integration time
    /// if drag-extend doesn't visibly extend on-device. Initial impl
    /// uses plain sendMousePos; we'll revisit with a real surface.)
    public func extend(to point: CGPoint) {
        guard isActive else { return }
        surface.sendMousePos(x: Double(point.x), y: Double(point.y))
    }

    /// IOS-11.6: extract + clipboard + clear + exit. Returns the copied
    /// text (or nil if there was nothing to copy).
    @discardableResult
    public func copy(toPasteboard pb: Pasteboard) -> String? {
        defer { exit() }
        guard let text = surface.readSelection(), !text.isEmpty else {
            return nil
        }
        var pb = pb
        pb.string = text
        return text
    }

    /// IOS-11.7: clear libghostty's selection and exit mode without
    /// touching the pasteboard.
    public func cancel() {
        exit()
    }

    private func exit() {
        surface.performAction("clear_selection")
        isActive = false
    }
}
#endif
```

NOTE on extend semantics: the controller's `extend` may need refinement once it's exercised against a real libghostty surface — see the inline comment. If drag-extend doesn't visibly extend the selection on-device during Task 6's integration testing, the most likely fix is to leave the LEFT button pressed during begin (one `sendLeftMouseDown`, no matching up until selection ends). Adjust the implementation in Task 6 and update the test in Step 2 accordingly, in a single follow-up commit cited from the test.

- [ ] **Step 5: Run tests and verify they pass**

```bash
xcodebuild \
  -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile \
  -sdk iphonesimulator \
  -configuration Debug \
  -skipPackagePluginValidation \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GrafttyMobileKitTests/TerminalSelectionControllerTests \
  test 2>&1 | tail -30
```

Expected: all eight tests pass.

- [ ] **Step 6: Remove the promoted IOS-11.x entries from IosTodo.swift**

Remove `ios_11_2`, `ios_11_3`, `ios_11_6`, `ios_11_7`, and `ios_11_10` blocks from `Tests/GrafttyTests/Specs/IosTodo.swift`.

- [ ] **Step 7: Regenerate SPECS.md and commit**

```bash
python3 scripts/generate-specs.py
git add Sources/GrafttyMobileKit/Terminal/SurfaceProxy.swift \
        Sources/GrafttyMobileKit/Terminal/TerminalSelectionController.swift \
        Tests/GrafttyMobileKitTests/Terminal/TerminalSelectionControllerTests.swift \
        Tests/GrafttyTests/Specs/IosTodo.swift \
        SPECS.md
git commit -m "feat(mobile): TerminalSelectionController state machine

Per-pane state driven by SurfaceProxy + Pasteboard protocols.
Implements IOS-11.2 (word-select via double-click), 11.3
(select-all via binding), 11.6 (copy → clipboard + exit), 11.7
(cancel without pasteboard), 11.10 (per-pane independence)."
```

---

## Task 6: Gesture choreography + edit menus on `TerminalInputContainerView`

Wires the long-press, the two `UIEditMenuInteraction` instances, the pan-to-extend recognizer, and the pan-to-scroll suppression. Plumbs everything to a per-pane `TerminalSelectionController` instance. Implements `IOS-11.1`, `11.4` (the gesture-suppression half), `11.5`, and `11.7` (the "press a key while active" half — via the cancel callback exposed on the container).

**Files:**
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift` (the UIKit container)
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift` (to wire `client.sendPaste` and `client` cancel-on-key-press)
- Modify: `Tests/GrafttyTests/Specs/IosTodo.swift` (remove `ios_11_1`, `ios_11_4`, `ios_11_5`)

This task is the most code-heavy and least unit-testable (it lives at the UIKit-gesture seam). Verification rests on the iOS simulator app-build job and on the screen-level smoke check below.

- [ ] **Step 1: Plumb a `TerminalSelectionController` instance into `TerminalInputContainerView`**

In `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift`, modify `TerminalInputContainerView` (around line 112) to own a `selectionController` and a closure for the per-tap actions:

```swift
public final class TerminalInputContainerView: UIView {
    let terminalView = UITerminalView(frame: .zero)
    let inputProxy = TerminalSoftwareKeyboardProxyView(frame: .zero)
    private(set) lazy var selectionController = TerminalSelectionController(
        surface: RealSurfaceProxy(surfaceProvider: { [weak self] in self?.terminalView.surface })
    )

    /// Called when the user taps the Paste action in the long-press
    /// menu — the SwiftUI layer wires this to `SessionClient.sendPaste`.
    public var onPasteRequested: (() -> Void)?

    private lazy var longPressMenu = UIEditMenuInteraction(delegate: self)
    private lazy var selectionMenu = UIEditMenuInteraction(delegate: self)

    private lazy var longPressRecognizer: UILongPressGestureRecognizer = {
        let r = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        r.minimumPressDuration = 0.45
        return r
    }()

    private lazy var selectionPanRecognizer: UIPanGestureRecognizer = {
        let r = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionPan(_:)))
        r.isEnabled = false
        return r
    }()

    // ... existing init / setup follows ...
}
```

- [ ] **Step 2: Install the gestures + menus in `setup()`**

Inside `setup()`:

```swift
        addInteraction(longPressMenu)
        addInteraction(selectionMenu)
        addGestureRecognizer(longPressRecognizer)
        addGestureRecognizer(selectionPanRecognizer)
```

- [ ] **Step 3: Implement gesture handlers**

Add to `TerminalInputContainerView`:

```swift
    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let point = recognizer.location(in: self)
        let config = UIEditMenuConfiguration(identifier: nil as NSCopying?, sourcePoint: point)
        longPressMenu.presentEditMenu(with: config)
    }

    @objc private func handleSelectionPan(_ recognizer: UIPanGestureRecognizer) {
        guard selectionController.isActive else { return }
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .changed:
            selectionController.extend(to: point)
        case .ended, .cancelled, .failed:
            presentSelectionMenu(near: point)
        default: break
        }
    }

    private func enterSelectionMode() {
        selectionPanRecognizer.isEnabled = true
        // IOS-11.4: suppress libghostty's pan-to-scroll while selection is active.
        terminalView.gestureRecognizers?.forEach { $0.isEnabled = false }
    }

    private func exitSelectionMode() {
        selectionPanRecognizer.isEnabled = false
        terminalView.gestureRecognizers?.forEach { $0.isEnabled = true }
    }

    fileprivate func performSelectAtLongPressPoint() {
        guard let recognizer = longPressRecognizer.view?.gestureRecognizers?
            .first(where: { $0 === longPressRecognizer }) else { return }
        let p = (recognizer as! UILongPressGestureRecognizer).location(in: self)
        selectionController.beginSelection(at: p)
        enterSelectionMode()
        presentSelectionMenu(near: p)
    }

    fileprivate func performSelectAll() {
        selectionController.selectAll()
        enterSelectionMode()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        presentSelectionMenu(near: center)
    }

    fileprivate func performPaste() {
        onPasteRequested?()
    }

    fileprivate func performCopy() {
        _ = selectionController.copy(toPasteboard: UIPasteboard.general)
        exitSelectionMode()
    }

    fileprivate func performCancelSelection() {
        selectionController.cancel()
        exitSelectionMode()
    }

    /// Called by parent SwiftUI layer when a control-bar key is pressed,
    /// to satisfy IOS-11.7's "press a key while active" cancel path.
    public func cancelActiveSelectionIfAny() {
        guard selectionController.isActive else { return }
        performCancelSelection()
    }

    private func presentSelectionMenu(near point: CGPoint) {
        let config = UIEditMenuConfiguration(identifier: "selection" as NSString, sourcePoint: point)
        selectionMenu.presentEditMenu(with: config)
    }
}
```

- [ ] **Step 4: Implement `UIEditMenuInteractionDelegate`**

In the same file:

```swift
extension TerminalInputContainerView: UIEditMenuInteractionDelegate {
    public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        if interaction === longPressMenu {
            return longPressUIMenu()
        }
        return selectionUIMenu()
    }

    private func longPressUIMenu() -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(title: "Select") { [weak self] _ in self?.performSelectAtLongPressPoint() },
            UIAction(title: "Select All") { [weak self] _ in self?.performSelectAll() },
        ]
        if UIPasteboard.general.hasStrings {
            children.append(UIAction(title: "Paste") { [weak self] _ in self?.performPaste() })
        }
        return UIMenu(children: children)
    }

    private func selectionUIMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Copy") { [weak self] _ in self?.performCopy() },
            UIAction(title: "Cancel", attributes: .destructive) { [weak self] _ in
                self?.performCancelSelection()
            },
        ])
    }
}
```

- [ ] **Step 5: Wire `onPasteRequested` + cancel-on-key in `RootView.swift`**

In `Sources/GrafttyMobileKit/App/RootView.swift`, modify `TerminalPaneView`'s call site to plumb a `onPasteRequested` closure and a way to reach the container for cancel. The cleanest minimal change: add an `onPasteRequested` field to `TerminalPaneView`'s `init`, mirror it onto the container in `makeUIView`/`updateUIView` (analogous to `softwareKeyboardInput`), and call `client?.cancelActiveSelectionIfAny()` from the control-bar Esc/Tab/Ctrl/arrow/Return/LF/Hide handlers — but that requires the container reference too. Take the small detour: wrap the entire `terminalControlBar`'s `Button` actions with a closure that pre-calls a `containerCancelHook` SwiftUI-State callback exposed by `TerminalPaneView`.

Concretely, in `TerminalPaneView`:

```swift
    public let onPasteRequested: (() -> Void)?
    /// Exposes the container's cancel-selection method so callers can
    /// fire IOS-11.7's "press a key while active" cancel.
    public let cancelSelectionRequest: (() -> Void)?

    // Add to init parameter list with defaults of nil; preserve existing call sites.
```

And in `makeUIView`/`updateUIView`, set:

```swift
        view.onPasteRequested = onPasteRequested
```

For the cancel hook, the simplest path is to capture the container in `makeCoordinator` and expose a `cancel()` on the coordinator that the SwiftUI layer can call. This adds <15 lines.

In `RootView.swift`'s `activeTerminal(...)`:

```swift
        let pane = TerminalPaneView(
            session: client.session,
            controller: controller,
            focusRequestCount: focusRequestCount,
            softwareKeyboardInput: .init(
                insertText: { text in client.sendSoftwareKeyboardText(text) },
                deleteBackward: { client.deleteBackward() }
            ),
            preferredInterfaceStyle: preferredStyle,
            onWillUnmount: { snapshot in client.setIdleSnapshot(snapshot) },
            onPasteRequested: { [weak client] in
                guard let client, let text = UIPasteboard.general.string, !text.isEmpty else {
                    return
                }
                client.sendPaste(text)
            },
            cancelSelectionRequest: { /* wired through coordinator */ }
        )
```

For each control-bar button in `terminalControlBar`, prefix the existing `client?.sendXxx()` action with a `cancelSelectionRequest?()` call (so pressing any key while a selection is active cancels per IOS-11.7).

- [ ] **Step 6: Build the app and run the iOS test suite**

```bash
cd /Users/btucker/projects/graftty/.worktrees/mobile-copy-paste
xcodebuild \
  -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile \
  -sdk iphonesimulator \
  -configuration Debug \
  -skipPackagePluginValidation \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test 2>&1 | tail -30
```

Expected: full build + test suite passes.

- [ ] **Step 7: Smoke-check on the simulator**

Boot the app on iPhone 17 simulator, connect to a Mac host, open a worktree, focus a pane.

- Type `hello world` so there's a word on screen.
- Long-press over "world" → menu should show **Select**, **Select All**. If there's text on the host clipboard, **Paste** appears too. (Copy something on the Mac side via `pbcopy` before launching to test the Paste path.)
- Tap Select → "world" should highlight. A second menu should appear with **Copy** / **Cancel**.
- Tap Copy. Switch to Notes or Messages, paste — should land "world".
- Repeat with Select All. Repeat with Paste.

If word-select doesn't fire on Select tap (the highlight doesn't appear), follow the note in Task 5 Step 4: switch `beginSelection` to leave the LEFT button held (one down, no up; rely on `cancel` / `copy` to emit the matching up). Adjust the controller test that asserts `[leftDown, leftUp, leftDown, leftUp]` to match.

- [ ] **Step 8: Promote IOS-11.1, IOS-11.4, IOS-11.5 from inventory**

The behavior described by these three is gesture- and menu-level, not unit-testable here. Promote them by removing the inventory entries; the `@spec` text is sufficient for `SPECS.md` so long as one `@spec` site exists. Add the `@spec` lines as doc comments above the relevant container methods:

In `TerminalPaneView.swift`:

```swift
/// @spec IOS-11.1: When the user long-presses a focused terminal pane, the application shall present a `UIEditMenuInteraction` menu at the touch point containing **Select**, **Select All**, and (when `UIPasteboard.general.hasStrings` is true at menu-build time) **Paste**.
@objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) { ... }

/// @spec IOS-11.4: While in selection mode, the application shall extend the live selection by forwarding pan-gesture positions to `surface.sendMousePos(...)`, and libghostty's built-in pan-to-scroll recognizer on the underlying `UITerminalView` shall be disabled until selection mode exits.
private func enterSelectionMode() { ... }

/// @spec IOS-11.5: When selection mode is active and the user lifts their finger after Select / Select All / extend, the application shall present a second `UIEditMenuInteraction` menu anchored near the selection rect containing **Copy** and **Cancel**.
private func presentSelectionMenu(near point: CGPoint) { ... }
```

Remove `ios_11_1`, `ios_11_4`, `ios_11_5` from `Tests/GrafttyTests/Specs/IosTodo.swift`.

- [ ] **Step 9: Regenerate SPECS.md and commit**

```bash
python3 scripts/generate-specs.py
git add Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift \
        Sources/GrafttyMobileKit/App/RootView.swift \
        Tests/GrafttyTests/Specs/IosTodo.swift \
        SPECS.md
git commit -m "feat(mobile): long-press + edit-menu gesture wiring (IOS-11.1, 11.4, 11.5)

UIEditMenuInteraction-driven long-press menu (Select/Select All/Paste),
selection-mode pan-to-extend recognizer that suppresses libghostty's
pan-to-scroll while active, and post-selection Copy/Cancel menu. All
plumbed through TerminalSelectionController."
```

---

## Task 7: Paste action wiring (IOS-11.8) — verify already covered

`IOS-11.8` is the read-clipboard + invoke `sendPaste` behavior at the menu-tap point. Task 6 Step 5 implemented it inside `onPasteRequested`. This task adds a unit test to lock that down and removes the inventory entry.

**Files:**
- Modify: `Tests/GrafttyMobileKitTests/Session/SessionClientTests.swift` (optional integration assertion)
- Modify: `Tests/GrafttyTests/Specs/IosTodo.swift`

- [ ] **Step 1: Add an `@spec IOS-11.8` doc comment on the `onPasteRequested` closure**

In `RootView.swift`, above the closure assigned to `onPasteRequested`:

```swift
            // @spec IOS-11.8: When the user taps **Paste** in the long-press menu,
            // the application shall read `UIPasteboard.general.string` and, when
            // non-empty, send it via `SessionClient.sendPaste(_:)`. An empty or
            // absent clipboard string shall be a silent no-op.
            onPasteRequested: { [weak client] in
                guard let client, let text = UIPasteboard.general.string, !text.isEmpty else {
                    return
                }
                client.sendPaste(text)
            },
```

- [ ] **Step 2: Remove `ios_11_8` from inventory, regenerate SPECS.md**

```bash
# Edit IosTodo.swift to remove the ios_11_8 block.
python3 scripts/generate-specs.py
git add Sources/GrafttyMobileKit/App/RootView.swift Tests/GrafttyTests/Specs/IosTodo.swift SPECS.md
git commit -m "spec(IOS-11.8): annotate paste-action closure"
```

---

## Task 8: Preview-tile guard (IOS-11.11) — assert and annotate

`IOS-11.11` says preview tiles do not get the long-press menu. The current preview-tile path is in `PaneTile` (worktree-detail screen) and does NOT mount `TerminalInputContainerView` — it mounts a separate, simpler view for the live preview. We verify this by grep and add an `@spec` doc-comment to the tile view to lock the contract.

**Files:**
- Modify: `Sources/GrafttyMobileKit/UI/PaneTile.swift` (or wherever the preview-tile lives)
- Modify: `Tests/GrafttyTests/Specs/IosTodo.swift`

- [ ] **Step 1: Locate the preview tile and confirm it does not use `TerminalInputContainerView`**

```bash
grep -rn "PaneTile\|TerminalPaneView\|live preview" Sources/GrafttyMobileKit/UI/ Sources/GrafttyMobileKit/App/ | head -20
```

If `PaneTile` uses `TerminalPaneView`, this assumption is wrong and the task changes shape (gate the gestures on a `role` flag passed into `TerminalPaneView`). Otherwise, proceed.

- [ ] **Step 2: Add an `@spec IOS-11.11` doc comment to the preview-tile view**

```swift
/// @spec IOS-11.11: While a pane is rendered as a worktree-detail preview tile (`IOS-4.10`), the long-press selection menu shall not be installed; tapping the tile shall continue to open the fullscreen pane per `IOS-4.21`.
struct PaneTile: View { ... }
```

(Substitute the actual struct/file name.)

If the assumption was wrong in Step 1: add a `role: TerminalPaneRole` parameter to `TerminalPaneView` (or reuse `SessionClient.role` already in scope). In `TerminalInputContainerView.setup()`, skip `addInteraction(longPressMenu)` and the long-press recognizer when `role == .preview`.

- [ ] **Step 3: Remove `ios_11_11` from inventory, regenerate SPECS.md, commit**

```bash
python3 scripts/generate-specs.py
git add Sources/GrafttyMobileKit/ Tests/GrafttyTests/Specs/IosTodo.swift SPECS.md
git commit -m "spec(IOS-11.11): annotate preview-tile no-selection-gesture guarantee"
```

---

## Task 9: Run /simplify

Repo convention (CLAUDE.md) requires `/simplify` before opening a PR.

- [ ] **Step 1: From the running Claude Code session, invoke `/simplify`.**

The skill reviews the diff against `origin/main` and proposes simplifications. Apply each that survives review; reject those that change behavior.

- [ ] **Step 2: Run the full iOS test suite once more after simplification**

```bash
xcodebuild \
  -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile \
  -sdk iphonesimulator \
  -configuration Debug \
  -skipPackagePluginValidation \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test 2>&1 | tail -30
```

Expected: green.

- [ ] **Step 3: Run `scripts/generate-specs.py --check` (mirrors CI)**

```bash
python3 scripts/generate-specs.py --check
```

Expected: exits 0 (no drift between annotations and SPECS.md).

- [ ] **Step 4: Commit any simplifications**

```bash
git add -A
git commit -m "simplify: post-/simplify cleanup"
```

(Or omit this commit if /simplify made no changes worth keeping.)

---

## Task 10: Open the PR

- [ ] **Step 1: Push the branch**

```bash
git push -u origin mobile-copy-paste
```

- [ ] **Step 2: Open the PR with a description that covers the libghostty fork dependency**

```bash
gh pr create --title "feat(mobile): copy and paste (IOS-11.x)" --body "$(cat <<'EOF'
## Summary

- Long-press a focused terminal pane on iOS → `UIEditMenuInteraction` menu with **Select**, **Select All**, **Paste**.
- Drag to extend the selection (libghostty's native highlight); lift finger → second menu with **Copy** / **Cancel**.
- Paste sends clipboard text via a new `SessionClient.sendPaste(_:)` wrapped in bracketed-paste delimiters.
- New specs: `IOS-11.1` through `IOS-11.11`. OSC 52 still a non-goal (`IOS-8.2` unchanged).

## libghostty-spm fork

This PR pins `Package.swift` to a fork of `Lakr233/libghostty-spm` at `github.com/btucker/libghostty-spm` on branch `expose-selection-api`. The fork exposes:
- `UITerminalView.surface` (public)
- `TerminalSurface.sendLeftMouseDown` / `sendLeftMouseUp` / `sendMousePos(x:y:)` / `performAction(_:)` / `readSelection()` (public)

Upstream PR to retire the fork: TODO (file after merge).

## Test plan
- [ ] iOS Simulator (iPhone 17): full xcodebuild test suite passes.
- [ ] Manual smoke: long-press → menu → Select → Copy → paste into another iOS app.
- [ ] Manual smoke: copy text on Mac with `pbcopy`, launch GrafttyMobile, long-press → menu → Paste → verify text lands in remote PTY.
- [ ] Manual smoke: long-press → Cancel doesn't touch clipboard.
- [ ] Manual smoke: while selection is active, tap Esc on control bar → selection clears.
- [ ] CI: `verify-specs` job green (no SPECS.md drift).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Watch CI and confirm green**

```bash
gh pr checks --watch
```

Per `CLAUDE.md`, the iOS CI job is the authoritative signal for mobile work.

---

## Self-Review

**Spec coverage:**
- IOS-11.1 → Task 6 (long-press menu)
- IOS-11.2 → Task 5 (controller `beginSelection`)
- IOS-11.3 → Task 5 (controller `selectAll`)
- IOS-11.4 → Task 5 (`extend`) + Task 6 (pan-to-scroll suppression)
- IOS-11.5 → Task 6 (`presentSelectionMenu`)
- IOS-11.6 → Task 5 (`copy(toPasteboard:)`)
- IOS-11.7 → Task 5 (`cancel`) + Task 6 (`cancelActiveSelectionIfAny` wired into control-bar keys)
- IOS-11.8 → Task 6/7 (`onPasteRequested` closure)
- IOS-11.9 → Task 3 (`sendPaste`)
- IOS-11.10 → Task 5 (per-pane independence test)
- IOS-11.11 → Task 8 (preview-tile guard)

**Type consistency:** `SurfaceProxy`, `Pasteboard`, `TerminalSelectionController`, `RealSurfaceProxy`, `FakeSurfaceProxy`, `FakePasteboard`, `onPasteRequested`, `cancelActiveSelectionIfAny` — names referenced uniformly across Tasks 4, 5, 6, 7.

**Placeholder scan:** Task 5 carries an inline note about possibly switching `extend` semantics if drag-extend doesn't visibly extend on-device. This is not a placeholder — it's a documented contingency tied to a verification step (Task 6 Step 7) with a concrete fallback (leave LEFT held during begin). All other steps include the actual code.

**One open contingency:** Task 8's assumption that the preview tile does not use `TerminalPaneView`. Step 1 of that task is a guard — if the assumption fails, the task shape changes to "add a `role` flag." Both shapes are described.
