# Default Command Setting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a global "Default command" setting that auto-types a user-configured command (e.g., `claude`) into the first pane of a freshly-opened worktree once the shell is ready.

**Architecture:** UserDefaults-backed settings via `@AppStorage`, a SwiftUI `Settings` scene, a pure decision function in `EspalierKit` (unit-testable), and a new `onShellReady` callback on `TerminalManager` derived from the first `GHOSTTY_ACTION_PWD` event per pane. Injection happens by typing the command into the surface via `ghostty_surface_text`.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, libghostty (via GhosttyKit), SwiftPM.

**Reference spec:** `docs/superpowers/specs/2026-04-17-default-command-design.md`

---

## File Structure

**New files:**
- `Sources/EspalierKit/DefaultCommandDecision.swift` — pure function deciding whether to inject a command and what to type. No UI or system dependencies.
- `Tests/EspalierKitTests/DefaultCommandDecisionTests.swift` — unit tests covering the decision matrix.
- `Sources/Espalier/Views/SettingsView.swift` — SwiftUI preferences pane (TextField + Toggle + footer text).

**Modified files:**
- `Sources/Espalier/Terminal/SurfaceHandle.swift` — add `typeText(_:)` method that forwards to `ghostty_surface_text`.
- `Sources/Espalier/Terminal/TerminalManager.swift` — add `onShellReady` callback, `shellReadyFired` / `firstPaneMarkers` / `rehydratedSurfaces` tracking sets, `markFirstPane` / `markRehydrated` / `isFirstPane` / `wasRehydrated` methods, destroy-time cleanup, and fire-on-first-PWD logic inside the existing `GHOSTTY_ACTION_PWD` case.
- `Sources/Espalier/EspalierApp.swift` — add `Settings { SettingsView() }` scene, wire `terminalManager.onShellReady`, add `maybeRunDefaultCommand` static function, call `markRehydrated` inside `restoreRunningWorktrees`.
- `Sources/Espalier/Views/MainWindow.swift` — inside `selectWorktree` after `createSurfaces`, call `terminalManager.markFirstPane(<first leaf id>)`.

---

## Task 1: Pure decision function + unit tests

**Files:**
- Create: `Sources/EspalierKit/DefaultCommandDecision.swift`
- Create: `Tests/EspalierKitTests/DefaultCommandDecisionTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/EspalierKitTests/DefaultCommandDecisionTests.swift`:

```swift
import XCTest
@testable import EspalierKit

final class DefaultCommandDecisionTests: XCTestCase {
    func testEmptyCommandSkips() {
        let decision = defaultCommandDecision(
            defaultCommand: "",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false
        )
        XCTAssertEqual(decision, .skip)
    }

    func testEmptyCommandSkipsEvenWhenRehydratedFalseAndFirstPaneFalse() {
        let decision = defaultCommandDecision(
            defaultCommand: "",
            firstPaneOnly: false,
            isFirstPane: false,
            wasRehydrated: false
        )
        XCTAssertEqual(decision, .skip)
    }

    func testRehydratedPaneSkipsRegardlessOfOtherInputs() {
        let decision = defaultCommandDecision(
            defaultCommand: "claude",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: true
        )
        XCTAssertEqual(decision, .skip)
    }

    func testFirstPaneTypesCommand() {
        let decision = defaultCommandDecision(
            defaultCommand: "claude",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false
        )
        XCTAssertEqual(decision, .type("claude"))
    }

    func testNonFirstPaneSkipsWhenFirstPaneOnlyIsTrue() {
        let decision = defaultCommandDecision(
            defaultCommand: "claude",
            firstPaneOnly: true,
            isFirstPane: false,
            wasRehydrated: false
        )
        XCTAssertEqual(decision, .skip)
    }

    func testNonFirstPaneTypesCommandWhenFirstPaneOnlyIsFalse() {
        let decision = defaultCommandDecision(
            defaultCommand: "claude",
            firstPaneOnly: false,
            isFirstPane: false,
            wasRehydrated: false
        )
        XCTAssertEqual(decision, .type("claude"))
    }

    func testFirstPaneTypesCommandWhenFirstPaneOnlyIsFalse() {
        let decision = defaultCommandDecision(
            defaultCommand: "npm run dev",
            firstPaneOnly: false,
            isFirstPane: true,
            wasRehydrated: false
        )
        XCTAssertEqual(decision, .type("npm run dev"))
    }

    func testWhitespaceOnlyCommandSkips() {
        let decision = defaultCommandDecision(
            defaultCommand: "   ",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false
        )
        XCTAssertEqual(decision, .skip)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (symbol missing)**

Run: `swift test --filter DefaultCommandDecisionTests 2>&1 | tail -20`
Expected: compilation error — `cannot find 'defaultCommandDecision' in scope` and `cannot find type 'DefaultCommandDecision' in scope`.

- [ ] **Step 3: Implement the pure function**

Create `Sources/EspalierKit/DefaultCommandDecision.swift`:

```swift
import Foundation

/// Decision about what to do when a pane's shell becomes ready.
public enum DefaultCommandDecision: Equatable, Sendable {
    case skip
    case type(String)
}

/// Pure decision function for whether to auto-type the user's default
/// command into a freshly-ready pane. Extracted from the UI layer so it
/// can be exercised without a running NSApplication or libghostty surface.
///
/// - Parameters:
///   - defaultCommand: The user's configured command string (from
///     `@AppStorage("defaultCommand")`). Empty or whitespace-only disables
///     the feature.
///   - firstPaneOnly: Whether the command should only fire on the first
///     pane of a worktree. When `false`, fires on every pane.
///   - isFirstPane: Whether this specific pane is the first pane of its
///     worktree (i.e., the pane that caused `.closed → .running`).
///   - wasRehydrated: Whether this pane was recreated by the
///     restore-on-launch path. Rehydrated panes never auto-run — the
///     command is already presumed running under zmx.
public func defaultCommandDecision(
    defaultCommand: String,
    firstPaneOnly: Bool,
    isFirstPane: Bool,
    wasRehydrated: Bool
) -> DefaultCommandDecision {
    let trimmed = defaultCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .skip }
    if wasRehydrated { return .skip }
    if firstPaneOnly && !isFirstPane { return .skip }
    return .type(trimmed)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DefaultCommandDecisionTests 2>&1 | tail -20`
Expected: `Test Suite 'DefaultCommandDecisionTests' passed` with 8 tests executed, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/EspalierKit/DefaultCommandDecision.swift \
       Tests/EspalierKitTests/DefaultCommandDecisionTests.swift
git commit -m "feat(kit): add DefaultCommandDecision pure function + tests

Extracts the 'should we auto-type the default command?' gating logic
into EspalierKit so it can be unit-tested without NSApplication.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: SurfaceHandle.typeText method

**Files:**
- Modify: `Sources/Espalier/Terminal/SurfaceHandle.swift` (add method inside the `SurfaceHandle` class, before the `requestClose()` method near line 198)

- [ ] **Step 1: Add `typeText` method**

Open `Sources/Espalier/Terminal/SurfaceHandle.swift`. Locate the `requestClose()` method (near line 198). Add directly *above* it:

```swift
    /// Programmatically inject text into the surface's PTY, as if the user
    /// had typed it. Routed through libghostty's `ghostty_surface_text`,
    /// the same entry point `SurfaceNSView.insertText` uses for keyboard
    /// input. Passing `"claude\r"` behaves identically to typing "claude"
    /// and pressing Return — it enters shell history, supports ↑ recall,
    /// and its child process lives and dies inside the surrounding shell.
    func typeText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let ptr = base.assumingMemoryBound(to: CChar.self)
            ghostty_surface_text(surface, ptr, UInt(raw.count))
        }
    }
```

- [ ] **Step 2: Build to verify**

Run: `swift build --target Espalier 2>&1 | tail -15`
Expected: `Build complete!` (warnings about `Sendable` are pre-existing and unrelated).

- [ ] **Step 3: Commit**

```bash
git add Sources/Espalier/Terminal/SurfaceHandle.swift
git commit -m "feat(surface): add typeText for programmatic PTY input

Forwards a UTF-8 string into ghostty_surface_text, the same path the
NSView uses for keyboard input. Enables auto-typing a default command
into a newly-ready pane.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: TerminalManager — onShellReady callback and tracking state

**Files:**
- Modify: `Sources/Espalier/Terminal/TerminalManager.swift`

- [ ] **Step 1: Add the `onShellReady` callback and tracking state**

Locate the `onCommandFinished` property (near line 91). Directly *after* it, add:

```swift
    /// Fired exactly once per `TerminalID` — on the first
    /// `GHOSTTY_ACTION_PWD` event received for that pane. This is our
    /// "shell is ready to accept typed input" signal: Ghostty's shell
    /// integration emits OSC 7 from `precmd`, which runs before every
    /// prompt including the first one. If shell integration is absent
    /// (or the user is using an unsupported shell), this callback
    /// never fires — consumers should treat that as a silent no-op
    /// rather than fall back to time-based heuristics.
    var onShellReady: ((TerminalID) -> Void)?
```

Next, find the section declaring private state near the top of the class (search for `private var surfaces:`). Directly after `private var surfaces: [TerminalID: SurfaceHandle] = [:]` (or adjacent private state), add:

```swift
    /// Terminal IDs for which `onShellReady` has already fired. Used to
    /// gate the callback to exactly one invocation per pane.
    private var shellReadyFired: Set<TerminalID> = []

    /// Terminal IDs that are the "first pane" of a worktree — the pane
    /// whose creation caused `.closed → .running`. Populated by
    /// `markFirstPane(_:)` from the sidebar/open-worktree path.
    private var firstPaneMarkers: Set<TerminalID> = []

    /// Terminal IDs that were recreated by restore-on-launch rather than
    /// user-initiated open. Populated by `markRehydrated(_:)` from
    /// `EspalierApp.restoreRunningWorktrees`.
    private var rehydratedSurfaces: Set<TerminalID> = []
```

- [ ] **Step 2: Add the marker API**

Locate the `destroySurface(terminalID:)` method (near line 259). Directly *after* it, add:

```swift
    /// Mark a terminal as the first pane of its worktree — the pane whose
    /// creation caused the worktree to transition from `.closed` to
    /// `.running`. Called by the sidebar "Open" action (and any other
    /// caller that triggers a `.closed → .running` transition).
    func markFirstPane(_ terminalID: TerminalID) {
        firstPaneMarkers.insert(terminalID)
    }

    /// Mark a terminal as rehydrated from on-disk state at launch, rather
    /// than freshly opened by the user. Rehydrated panes never auto-run
    /// a default command — the command is presumed already running under
    /// zmx from the previous session. Called by
    /// `EspalierApp.restoreRunningWorktrees` before creating surfaces.
    func markRehydrated(_ terminalID: TerminalID) {
        rehydratedSurfaces.insert(terminalID)
    }

    /// Whether a terminal was marked as the first pane of its worktree.
    func isFirstPane(_ terminalID: TerminalID) -> Bool {
        firstPaneMarkers.contains(terminalID)
    }

    /// Whether a terminal was marked as rehydrated rather than user-opened.
    func wasRehydrated(_ terminalID: TerminalID) -> Bool {
        rehydratedSurfaces.contains(terminalID)
    }
```

- [ ] **Step 3: Clean up tracking state on destroy**

Locate `destroySurfaces(terminalIDs:)` (near line 250). The loop body already contains `killZmxSession(for: id)`. Add this line at the end of the loop body, after `killZmxSession(for: id)`:

```swift
            forgetTrackingState(for: id)
```

Do the same inside `destroySurface(terminalID:)` (near line 259) — add after its `killZmxSession(for: terminalID)` call:

```swift
        forgetTrackingState(for: terminalID)
```

Then add the helper method directly after `destroySurface`:

```swift
    /// Clear per-terminal tracking state on destroy. Keeps the three
    /// tracking sets in sync with live surfaces so destroyed IDs don't
    /// leak memory or cause stale answers from the marker queries.
    private func forgetTrackingState(for terminalID: TerminalID) {
        shellReadyFired.remove(terminalID)
        firstPaneMarkers.remove(terminalID)
        rehydratedSurfaces.remove(terminalID)
    }
```

- [ ] **Step 4: Fire `onShellReady` on the first PWD event**

Locate the `GHOSTTY_ACTION_PWD` case in `handleAction` (near line 360). Replace the existing case body:

```swift
        case GHOSTTY_ACTION_PWD:
            guard let id = terminalID(from: target) else { return }
            guard let pwdPtr = action.action.pwd.pwd else { return }
            let pwd = String(cString: pwdPtr)
            onPWDChange?(id, pwd)
```

with:

```swift
        case GHOSTTY_ACTION_PWD:
            guard let id = terminalID(from: target) else { return }
            guard let pwdPtr = action.action.pwd.pwd else { return }
            let pwd = String(cString: pwdPtr)
            onPWDChange?(id, pwd)
            if shellReadyFired.insert(id).inserted {
                onShellReady?(id)
            }
```

`Set.insert(_:)` returns `(inserted: Bool, memberAfterInsert: Element)`; checking `.inserted` guarantees the callback fires exactly once per `TerminalID`.

- [ ] **Step 5: Build to verify**

Run: `swift build --target Espalier 2>&1 | tail -10`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/Espalier/Terminal/TerminalManager.swift
git commit -m "feat(terminal): add onShellReady, first-pane + rehydration markers

Introduces the 'shell is ready to accept input' signal derived from the
first GHOSTTY_ACTION_PWD event per pane. Adds markFirstPane /
markRehydrated tracking so consumers can distinguish user-initiated
worktree opens from restore-on-launch and from split-within-worktree.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: SettingsView and Settings scene

**Files:**
- Create: `Sources/Espalier/Views/SettingsView.swift`
- Modify: `Sources/Espalier/EspalierApp.swift`

- [ ] **Step 1: Create the SettingsView**

Create `Sources/Espalier/Views/SettingsView.swift`:

```swift
import SwiftUI

/// Preferences pane for Espalier. Exposed via the SwiftUI `Settings` scene,
/// so the system adds a "Settings…" menu item under "About Espalier" and
/// binds the standard ⌘, shortcut automatically.
struct SettingsView: View {
    @AppStorage("defaultCommand") private var defaultCommand: String = ""
    @AppStorage("defaultCommandFirstPaneOnly") private var firstPaneOnly: Bool = true

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 440)
        .padding(20)
    }

    private var generalTab: some View {
        Form {
            TextField("Default command:", text: $defaultCommand, prompt: Text("e.g., claude"))
                .textFieldStyle(.roundedBorder)

            Toggle("Run in first pane only", isOn: $firstPaneOnly)

            Text("Runs automatically when a worktree opens. Leave empty to disable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2: Add the Settings scene to EspalierApp.body**

Open `Sources/Espalier/EspalierApp.swift`. Locate the `body` property's `WindowGroup { ... }` block. Directly *after* the closing brace of the `WindowGroup`'s trailing `.commands { ... }` modifier chain (i.e., as a sibling scene inside `body`), add:

```swift
        Settings {
            SettingsView()
        }
```

The enclosing `var body: some Scene { ... }` must return multiple scenes. Swift's `@SceneBuilder` accepts sibling scenes the same way `@ViewBuilder` accepts sibling views — no additional wrapper needed.

- [ ] **Step 3: Build to verify**

Run: `swift build --target Espalier 2>&1 | tail -10`
Expected: `Build complete!`

- [ ] **Step 4: Smoke test the Settings window**

Run: `./scripts/bundle.sh && open -n .build/Espalier.app`
Then: with the new instance focused, press ⌘, — expected: a preferences window opens with the General tab showing the text field and checkbox. Close it.

Verify: `defaults read com.espalier.app` should now list `defaultCommand` and `defaultCommandFirstPaneOnly` if you interacted with the controls.

- [ ] **Step 5: Commit**

```bash
git add Sources/Espalier/Views/SettingsView.swift Sources/Espalier/EspalierApp.swift
git commit -m "feat(settings): add SwiftUI Settings scene with default-command prefs

Introduces @AppStorage-backed 'defaultCommand' and
'defaultCommandFirstPaneOnly' keys, surfaced in a single-tab General
preferences pane reachable via ⌘, or the app menu. Live binding; no
Apply/Cancel buttons per macOS convention.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Wire `maybeRunDefaultCommand` in EspalierApp

**Files:**
- Modify: `Sources/Espalier/EspalierApp.swift`

- [ ] **Step 1: Add the `maybeRunDefaultCommand` static function**

Open `Sources/Espalier/EspalierApp.swift`. Locate the `closePane` static function (near line 629). Directly *after* its closing brace, add:

```swift
    /// Called on the first `onShellReady` signal for a pane. Reads the
    /// user's default-command preferences from UserDefaults, consults the
    /// pure decision function in EspalierKit, and — if the decision is
    /// `.type(command)` — types the command into the pane via
    /// `SurfaceHandle.typeText` followed by `\r` to trigger execution.
    @MainActor
    fileprivate static func maybeRunDefaultCommand(
        terminalManager: TerminalManager,
        terminalID: TerminalID
    ) {
        let defaults = UserDefaults.standard
        let command = defaults.string(forKey: "defaultCommand") ?? ""
        // `@AppStorage` defaults apply only in the SwiftUI view; when
        // read directly from UserDefaults the key returns nil on
        // first run. Treat nil as `true` to match the SettingsView default.
        let firstPaneOnly = defaults.object(forKey: "defaultCommandFirstPaneOnly") as? Bool ?? true

        let decision = defaultCommandDecision(
            defaultCommand: command,
            firstPaneOnly: firstPaneOnly,
            isFirstPane: terminalManager.isFirstPane(terminalID),
            wasRehydrated: terminalManager.wasRehydrated(terminalID)
        )

        switch decision {
        case .skip:
            return
        case .type(let trimmedCommand):
            terminalManager.handle(for: terminalID)?.typeText(trimmedCommand + "\r")
        }
    }
```

- [ ] **Step 2: Wire `onShellReady` in `startup()`**

Locate `startup()` in `EspalierApp.swift` (near line 121). Find the block where other terminal callbacks are wired — the existing `terminalManager.onPWDChange = { ... }` and `terminalManager.onCommandFinished = { ... }` assignments. Directly *after* `terminalManager.onCommandFinished = { ... }` (which ends around line 200), add:

```swift
        // First prompt on a newly-ready pane → maybe type the user's
        // default command. `maybeRunDefaultCommand` consults UserDefaults
        // and the TerminalManager's first-pane / rehydration markers to
        // decide; most of the time it's a no-op.
        terminalManager.onShellReady = { [tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                Self.maybeRunDefaultCommand(
                    terminalManager: tm,
                    terminalID: terminalID
                )
            }
        }
```

- [ ] **Step 3: Build to verify**

Run: `swift build --target Espalier 2>&1 | tail -10`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/Espalier/EspalierApp.swift
git commit -m "feat(app): wire default-command injection on first shell-ready

Adds maybeRunDefaultCommand — reads @AppStorage prefs, consults the
pure EspalierKit decision function, and types the command on .type
outcomes. Wired to TerminalManager.onShellReady in startup().

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Mark first-pane and rehydrated call sites

**Files:**
- Modify: `Sources/Espalier/Views/MainWindow.swift` (around line 203)
- Modify: `Sources/Espalier/EspalierApp.swift` (inside `restoreRunningWorktrees`, around line 288)

- [ ] **Step 1: Mark first pane in sidebar `selectWorktree`**

Open `Sources/Espalier/Views/MainWindow.swift`. Locate `selectWorktree(_:)` (near line 187). Find the block that transitions a closed worktree to running — specifically the section with `_ = terminalManager.createSurfaces(...)` followed by `appState.repos[repoIdx].worktrees[wtIdx].state = .running`. Replace that block:

```swift
                    if appState.repos[repoIdx].worktrees[wtIdx].splitTree.root == nil {
                        let id = TerminalID()
                        appState.repos[repoIdx].worktrees[wtIdx].splitTree = SplitTree(root: .leaf(id))
                    }

                    let splitTree = appState.repos[repoIdx].worktrees[wtIdx].splitTree
                    _ = terminalManager.createSurfaces(for: splitTree, worktreePath: path)

                    appState.repos[repoIdx].worktrees[wtIdx].state = .running
```

with:

```swift
                    if appState.repos[repoIdx].worktrees[wtIdx].splitTree.root == nil {
                        let id = TerminalID()
                        appState.repos[repoIdx].worktrees[wtIdx].splitTree = SplitTree(root: .leaf(id))
                    }

                    let splitTree = appState.repos[repoIdx].worktrees[wtIdx].splitTree
                    // Mark every leaf as a first-pane candidate *before*
                    // createSurfaces — the first PWD event could arrive
                    // immediately after the surface spawns, and
                    // maybeRunDefaultCommand queries isFirstPane at that
                    // time. In the common case there's exactly one leaf
                    // (fresh open); marking all of them keeps this robust
                    // against future layouts that seed multiple leaves.
                    for leafID in splitTree.allLeaves {
                        terminalManager.markFirstPane(leafID)
                    }
                    _ = terminalManager.createSurfaces(for: splitTree, worktreePath: path)

                    appState.repos[repoIdx].worktrees[wtIdx].state = .running
```

- [ ] **Step 2: Mark rehydrated panes in `restoreRunningWorktrees`**

Open `Sources/Espalier/EspalierApp.swift`. Locate `restoreRunningWorktrees()` (near line 288). Replace the function body:

```swift
    private func restoreRunningWorktrees() {
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                if wt.state == .running {
                    if wt.splitTree.root == nil {
                        let id = TerminalID()
                        appState.repos[repoIdx].worktrees[wtIdx].splitTree = SplitTree(root: .leaf(id))
                    }
                    _ = terminalManager.createSurfaces(
                        for: appState.repos[repoIdx].worktrees[wtIdx].splitTree,
                        worktreePath: wt.path
                    )
                }
            }
        }
```

with:

```swift
    private func restoreRunningWorktrees() {
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                if wt.state == .running {
                    if wt.splitTree.root == nil {
                        let id = TerminalID()
                        appState.repos[repoIdx].worktrees[wtIdx].splitTree = SplitTree(root: .leaf(id))
                    }
                    // Mark every restored leaf as rehydrated *before*
                    // surface creation so the first-PWD event (which
                    // triggers onShellReady) finds wasRehydrated == true
                    // and short-circuits command injection. Without this
                    // guard, relaunching Espalier would type the default
                    // command on top of whatever process is already
                    // running inside the persisted zmx session.
                    for leafID in appState.repos[repoIdx].worktrees[wtIdx].splitTree.allLeaves {
                        terminalManager.markRehydrated(leafID)
                    }
                    _ = terminalManager.createSurfaces(
                        for: appState.repos[repoIdx].worktrees[wtIdx].splitTree,
                        worktreePath: wt.path
                    )
                }
            }
        }
```

(Leave the rest of the function — the focus-setting block after the loop — unchanged.)

- [ ] **Step 3: Build to verify**

Run: `swift build --target Espalier 2>&1 | tail -10`
Expected: `Build complete!`

- [ ] **Step 4: Run the EspalierKit test suite**

Run: `swift test 2>&1 | tail -20`
Expected: `Test Suite 'All tests' passed`, `DefaultCommandDecisionTests` still included and green. This guards against an accidental regression in the pure function from any refactors during Tasks 2-6.

- [ ] **Step 5: Commit**

```bash
git add Sources/Espalier/Views/MainWindow.swift Sources/Espalier/EspalierApp.swift
git commit -m "feat(app): mark first-pane and rehydrated leaves at creation sites

Sidebar selectWorktree marks the first leaf(s) of a freshly-opened
worktree; restoreRunningWorktrees marks every leaf of a restored
worktree as rehydrated so the default command is not retyped on top
of an already-running process.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: End-to-end manual verification

**Files:** (none — manual verification only)

- [ ] **Step 1: Bundle the app and launch a fresh instance**

Run:

```bash
./scripts/bundle.sh && open -n .build/Espalier.app
```

- [ ] **Step 2: Set the default command**

In the new instance:
1. Press ⌘, to open Settings.
2. In the "Default command" field, type `echo hello-from-default-command`.
3. Leave "Run in first pane only" checked.
4. Close Settings.

- [ ] **Step 3: Verify on first-pane open**

In the sidebar, find a `.closed` worktree. Click it to open. Expected: a new pane spawns, the shell starts, and shortly after the prompt appears, `echo hello-from-default-command` is typed into the pane automatically and executed, printing `hello-from-default-command`. The prompt returns (you're back at zsh, not in a dead pane).

- [ ] **Step 4: Verify first-pane-only on split**

Inside the same worktree, press ⌘D to split horizontally. Expected: a new pane appears, zsh starts, but the `echo` command is NOT typed — the split is not the "first pane" of the worktree.

- [ ] **Step 5: Verify rehydration does not re-run**

Quit Espalier (⌘Q). Relaunch (`open -n .build/Espalier.app`). Expected: the worktree's pane restores with its existing zsh session (no new `echo` typed). You can confirm by checking that the pane does not show a second `hello-from-default-command` line after restoration.

- [ ] **Step 6: Verify firstPaneOnly=false**

Open Settings (⌘,), uncheck "Run in first pane only", close. Explicitly Stop the worktree (right-click → Stop). Open it again. Press ⌘D to split. Expected: the `echo` runs in the first pane AND in the split pane.

- [ ] **Step 7: Verify empty command disables**

Open Settings, clear the "Default command" field, close. Stop + reopen the worktree. Expected: no command is typed; the pane is an untouched shell prompt.

- [ ] **Step 8: Kill the test instance**

Locate the test instance (pid from `open -n`) and quit it. Your primary Espalier instance was never touched.

- [ ] **Step 9: No commit for this task** — manual verification only.

---

## Task 8: Open the pull request

**Files:** (none — git/gh operations only)

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feature/default-command
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "feat: default-command setting" --body "$(cat <<'EOF'
## Summary
- Adds a user-configurable "Default command" that auto-types into the first pane of a freshly-opened worktree once its shell is ready (e.g., `claude`).
- Adds a SwiftUI Settings scene (⌘,) with two controls: command text + "Run in first pane only" checkbox.
- Fires via the first `GHOSTTY_ACTION_PWD` event per pane; skips on restore-from-disk so relaunch does not retype over existing processes.
- Incidental: replaces `CommandMenu("Espalier")` with `CommandGroup(after: .appInfo)` so the menubar has one "Espalier" item instead of two.

See `docs/superpowers/specs/2026-04-17-default-command-design.md` for the full design.

## Test plan
- [x] `swift test` — `DefaultCommandDecisionTests` covers the gating matrix
- [x] Manual: first-pane open types the command; split does not; rehydration does not; empty command disables; unchecked firstPaneOnly fires on every pane
- [x] `swift build --target Espalier` clean

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Report the PR URL**

Print the URL `gh` returns so the user can open it in their browser.

---

## Self-Review Notes

1. **Spec coverage:**
   - Storage → Task 4 (`@AppStorage` keys) ✓
   - Settings UI → Task 4 ✓
   - Trigger (first PWD) → Task 3 (step 4) ✓
   - First-pane identity → Task 3 (marker API) + Task 6 (sidebar call site) ✓
   - Rehydration marker → Task 3 (marker API) + Task 6 (restore call site) ✓
   - `typeText` → Task 2 ✓
   - Pure decision function → Task 1 ✓
   - Edge cases (shell integration off, stop+reopen, OSC 7 migration, stale, settings mid-run, empty command) → covered by the decision function (tested in Task 1) and the "fires only on first PWD" semantic (wired in Task 3)

2. **Placeholder scan:** no TBDs, TODOs, "similar to earlier task" references, or unadorned "add error handling" directives. Every code step includes the literal code.

3. **Type consistency:**
   - `DefaultCommandDecision` / `defaultCommandDecision` — consistent across Tasks 1, 5.
   - `markFirstPane` / `markRehydrated` / `isFirstPane` / `wasRehydrated` — consistent between Task 3 (definitions) and Tasks 5, 6 (call sites).
   - `onShellReady: ((TerminalID) -> Void)?` — same signature in Task 3 (definition) and Task 5 (wiring).
   - UserDefaults keys `"defaultCommand"` / `"defaultCommandFirstPaneOnly"` — consistent between Task 4 (`@AppStorage`) and Task 5 (direct `UserDefaults` read).

4. **Scope:** single feature, eight tasks, ~500 lines of code changes in eight commits. Appropriate for one plan.
