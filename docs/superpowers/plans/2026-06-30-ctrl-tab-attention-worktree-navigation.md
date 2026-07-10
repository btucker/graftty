# Ctrl+Tab attention-first worktree navigation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ctrl+tab` in the Mac app jump to the next worktree that has requested attention (falling through to plain next-worktree when none do), with `ctrl+shift+tab` as the reverse.

**Architecture:** A pure, unit-tested selection function on `AppState` computes the target worktree path from the current selection + direction (attention subset first, then cyclic next). Two new `GhosttyAction` cases (`next_tab`/`previous_tab`) resolve the chords through the existing keybind bridge. A `@FocusedValue` bridges `GrafttyApp`'s `.commands` block to `MainWindow.selectWorktree`, reusing the same selection path (and its `acknowledgeAttention()`) sidebar clicks use.

**Tech Stack:** Swift, Swift Testing (GrafttyKit unit tests), SwiftUI (`.commands`, `@FocusedValue`), libghostty keybind bridge.

## Global Constraints

- `SPECS.md` is auto-generated — never hand-edit; run `scripts/generate-specs.py` and commit it alongside code.
- Spec IDs use EARS phrasing; a spec ID appears in at most one behavioral location. New IDs live under **KBD-5.x** (KBD 1–4 already exist and own keybind-driven navigation).
- No literal `"` double-quote characters inside `@spec` test titles (they silently truncate `SPECS.md`). Use backticks or rephrase.
- `GhosttyAction` raw values are the exact strings Ghostty's config parser accepts; they are pinned by `GhosttyActionTests` and must stay in sync.
- Follow existing patterns: `bridgedButton` for keybound menu items, `AddWorktreeFocusedValues.swift` for the scene-command→view bridge.
- Selectable worktrees = `state.hasOnDiskWorktree` (`.closed` / `.running`). `.stale` / `.creating` / `.deleting` are skipped.
- Attention = `attention != nil || !paneAttention.isEmpty`, any `AttentionSource`.

---

## File Structure

- `Sources/GrafttyKit/Model/AppState.swift` — add `nextWorktreePath(forward:)` (pure selection logic). [modify]
- `Tests/GrafttyKitTests/Model/WorktreeNavigationTests.swift` — KBD-5.x behavioral specs for the pure function. [create]
- `Sources/GrafttyKit/Keybinds/GhosttyAction.swift` — add `nextTab` / `previousTab` cases. [modify]
- `Tests/GrafttyKitTests/Keybinds/GhosttyActionTests.swift` — pin the two new raw values + bump the count. [modify]
- `Sources/Graftty/Views/WorktreeNavFocusedValues.swift` — `@FocusedValue` key for the worktree-nav closure. [create]
- `Sources/Graftty/Views/MainWindow.swift` — publish the closure; implement it via `nextWorktreePath` + `selectWorktree`. [modify]
- `Sources/Graftty/GrafttyApp.swift` — two `bridgedButton`s in the nav `CommandGroup`. [modify]
- `SPECS.md` — regenerated. [modify]

---

## Task 1: Pure worktree-selection logic (`AppState.nextWorktreePath`)

**Files:**
- Modify: `Sources/GrafttyKit/Model/AppState.swift`
- Test: `Tests/GrafttyKitTests/Model/WorktreeNavigationTests.swift` (create)

**Interfaces:**
- Consumes: `AppState.repos`, `AppState.selectedWorktreePath`, `AppState.worktree(forPath:)`, `WorktreeState.hasOnDiskWorktree`, `WorktreeEntry.attention`, `WorktreeEntry.paneAttention`.
- Produces: `func nextWorktreePath(forward: Bool) -> String?` on `AppState`.

**Reference — existing helpers you will call (do not redefine):**
- `AppState.worktree(forPath:) -> WorktreeEntry?` (AppState.swift:185)
- `WorktreeState.hasOnDiskWorktree` is `true` only for `.closed` / `.running` (WorktreeEntry.swift:43)
- `WorktreeEntry(path:branch:state:attention:splitTree:)` initializer (WorktreeEntry.swift:100); `state` defaults to `.closed`, `attention` to `nil`. `paneAttention` starts empty and is a settable `var`.
- `Attention(text:timestamp:source:)`; `AttentionSource` cases `.agentStop`, `.userNotify`, `.commandFinished`.
- `RepoEntry(path:displayName:worktrees:)` initializer (RepoEntry.swift:27) — `worktrees` defaults to `[]`; other args (`isCollapsed`, `bookmark`, `isGitTracked`, `defaultBranchHint`) default and are unused here.

- [ ] **Step 1: Write the failing tests**

Create `Tests/GrafttyKitTests/Model/WorktreeNavigationTests.swift`:

```swift
import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

@Suite("@spec KBD-5: ctrl+tab / ctrl+shift+tab worktree navigation — attention-first, else cyclic.")
struct WorktreeNavigationTests {

    // MARK: fixtures

    private func att() -> Attention {
        Attention(text: "needs input", timestamp: Date(timeIntervalSince1970: 1), source: .agentStop)
    }

    /// A worktree at `path`, optionally flagged with worktree-level attention,
    /// in a given on-disk-affecting state (default `.closed` = selectable).
    private func wt(_ path: String, attention: Bool = false, state: WorktreeState = .closed) -> WorktreeEntry {
        WorktreeEntry(path: path, branch: "b", state: state, attention: attention ? att() : nil)
    }

    /// Single-repo AppState from the given worktrees + current selection.
    private func state(_ worktrees: [WorktreeEntry], selected: String?) -> AppState {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: worktrees)
        return AppState(repos: [repo], selectedWorktreePath: selected)
    }

    // MARK: KBD-5.1 — attention worktree wins over plain next

    @Test("@spec KBD-5.1: When another on-disk worktree has attention, next_tab shall select the next attention-carrying worktree in cyclic sidebar order, skipping non-attention worktrees in between.")
    func forwardPrefersAttention() {
        // A(selected) B(no) C(attention) D(no)
        let s = state([wt("/a"), wt("/b"), wt("/c", attention: true), wt("/d")], selected: "/a")
        #expect(s.nextWorktreePath(forward: true) == "/c")
    }

    // MARK: KBD-5.2 — no attention anywhere → plain cyclic next

    @Test("@spec KBD-5.2: When no other worktree has attention, next_tab shall select the immediate next on-disk worktree in cyclic sidebar order.")
    func forwardPlainNext() {
        let s = state([wt("/a"), wt("/b"), wt("/c")], selected: "/a")
        #expect(s.nextWorktreePath(forward: true) == "/b")
    }

    @Test("@spec KBD-5.2: next_tab shall wrap from the last on-disk worktree back to the first when no worktree has attention.")
    func forwardWrapsAround() {
        let s = state([wt("/a"), wt("/b"), wt("/c")], selected: "/c")
        #expect(s.nextWorktreePath(forward: true) == "/a")
    }

    // MARK: KBD-5.3 — reverse

    @Test("@spec KBD-5.3: previous_tab shall apply attention-first selection in reverse cyclic order.")
    func reversePrefersAttention() {
        // A(attention) B(no) C(no) D(selected)
        let s = state([wt("/a", attention: true), wt("/b"), wt("/c"), wt("/d")], selected: "/d")
        #expect(s.nextWorktreePath(forward: false) == "/a")
    }

    @Test("@spec KBD-5.3: previous_tab shall select the immediate previous on-disk worktree (wrapping) when no worktree has attention.")
    func reversePlainPrevWraps() {
        let s = state([wt("/a"), wt("/b"), wt("/c")], selected: "/a")
        #expect(s.nextWorktreePath(forward: false) == "/c")
    }

    // MARK: KBD-5.4 — attention scope + current-excluded

    @Test("@spec KBD-5.4: Pane-scoped attention shall make a worktree a navigation target the same as worktree-scoped attention.")
    func paneAttentionCounts() {
        var b = wt("/b")
        b.paneAttention[PaneSlotID(id: UUID())] = att()
        let s = state([wt("/a"), b, wt("/c")], selected: "/a")
        #expect(s.nextWorktreePath(forward: true) == "/b")
    }

    @Test("@spec KBD-5.4: The currently-selected worktree shall be excluded from the attention subset, so its own attention does not trap navigation on itself.")
    func currentWithAttentionIsExcluded() {
        // A is selected AND has attention; B has attention. Forward must go to B, not stay on A.
        let s = state([wt("/a", attention: true), wt("/b", attention: true), wt("/c")], selected: "/a")
        #expect(s.nextWorktreePath(forward: true) == "/b")
    }

    @Test("@spec KBD-5.4: A userNotify or commandFinished attention source shall count the same as agentStop for navigation.")
    func anyAttentionSourceCounts() {
        let notify = Attention(text: "ping", timestamp: Date(timeIntervalSince1970: 2), source: .userNotify)
        var c = wt("/c")
        c.attention = notify
        let s = state([wt("/a"), wt("/b"), c], selected: "/a")
        #expect(s.nextWorktreePath(forward: true) == "/c")
    }

    // MARK: KBD-5.5 — 0/1 selectable → no-op

    @Test("@spec KBD-5.5: When zero or one on-disk worktree is selectable, next_tab and previous_tab shall be a no-op (return nil).")
    func oneOrZeroSelectableIsNoOp() {
        let one = state([wt("/a")], selected: "/a")
        #expect(one.nextWorktreePath(forward: true) == nil)
        #expect(one.nextWorktreePath(forward: false) == nil)

        // A selectable + a non-on-disk sibling still counts as one selectable.
        let plusStale = state([wt("/a"), wt("/s", attention: true, state: .stale)], selected: "/a")
        #expect(plusStale.nextWorktreePath(forward: true) == nil)
    }

    @Test("@spec KBD-5.5: Non-on-disk worktrees (.stale/.creating/.deleting) shall never be navigation targets, even when they carry attention.")
    func skipsNonOnDiskWorktrees() {
        // A(selected) STALE(attention) C(no). Stale must be skipped → land on C.
        let s = state([wt("/a"), wt("/stale", attention: true, state: .stale), wt("/c")], selected: "/a")
        #expect(s.nextWorktreePath(forward: true) == "/c")
    }

    // MARK: KBD-5.6 — no selection

    @Test("@spec KBD-5.6: When no worktree is selected, next_tab shall select the first attention worktree, else the first on-disk worktree; previous_tab shall select the last.")
    func noSelectionStartsAtEdges() {
        let plain = state([wt("/a"), wt("/b"), wt("/c")], selected: nil)
        #expect(plain.nextWorktreePath(forward: true) == "/a")
        #expect(plain.nextWorktreePath(forward: false) == "/c")

        let withAttn = state([wt("/a"), wt("/b", attention: true), wt("/c")], selected: nil)
        #expect(withAttn.nextWorktreePath(forward: true) == "/b")
    }

    // MARK: cross-repo ordering

    @Test("@spec KBD-5.1: Navigation order shall flatten worktrees across repos in sidebar order (repo order, then worktree order).")
    func flattensAcrossRepos() {
        let repo1 = RepoEntry(path: "/r1", displayName: "r1", worktrees: [wt("/a"), wt("/b")])
        let repo2 = RepoEntry(path: "/r2", displayName: "r2", worktrees: [wt("/c", attention: true)])
        let s = AppState(repos: [repo1, repo2], selectedWorktreePath: "/b")
        #expect(s.nextWorktreePath(forward: true) == "/c")
    }
}
```

- [ ] **Step 3: Run the tests to confirm they fail**

Run: `swift test --filter WorktreeNavigationTests`
Expected: FAIL — compile error `value of type 'AppState' has no member 'nextWorktreePath'` (and, if the `RepoEntry(path:name:worktrees:)` shape differs, fix the helper first per Step 1).

- [ ] **Step 4: Implement `nextWorktreePath(forward:)`**

Add to `Sources/GrafttyKit/Model/AppState.swift` (e.g. just after `indices(forWorktreePath:)`, before `private static let fileName`):

```swift
    /// Target worktree path for `ctrl+tab` (forward) / `ctrl+shift+tab`
    /// (reverse) — KBD-5. Worktrees requesting attention (any
    /// `AttentionSource`, worktree- or pane-scoped), excluding the current
    /// selection, take priority; otherwise the immediate next/previous
    /// selectable worktree. Cyclic over on-disk worktrees in sidebar order
    /// (repo order, then worktree order). Returns `nil` when there is
    /// nothing to move to (0 or 1 selectable worktrees).
    public func nextWorktreePath(forward: Bool) -> String? {
        let ordered: [String] = repos.flatMap { repo in
            repo.worktrees
                .filter { $0.state.hasOnDiskWorktree }
                .map { $0.path }
        }
        let n = ordered.count
        guard n > 1 else { return nil }

        func hasAttention(_ path: String) -> Bool {
            guard let wt = worktree(forPath: path) else { return false }
            return wt.attention != nil || !wt.paneAttention.isEmpty
        }

        // Indices to visit, in priority order, starting just after (forward)
        // or before (reverse) the current selection. When nothing selectable
        // is selected, walk the whole list from an edge.
        let searchOrder: [Int]
        if let ci = selectedWorktreePath.flatMap({ ordered.firstIndex(of: $0) }) {
            searchOrder = (1...(n - 1)).map { step in
                forward ? (ci + step) % n : (ci - step + n) % n
            }
        } else {
            searchOrder = forward ? Array(0..<n) : Array((0..<n).reversed())
        }

        // Attention worktree wins; the current selection is never in
        // `searchOrder` (steps 1..<n), so it is excluded automatically.
        if let hit = searchOrder.first(where: { hasAttention(ordered[$0]) }) {
            return ordered[hit]
        }
        return ordered[searchOrder[0]]
    }
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run: `swift test --filter WorktreeNavigationTests`
Expected: PASS (all cases).

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Model/AppState.swift Tests/GrafttyKitTests/Model/WorktreeNavigationTests.swift
git commit -m "feat(KBD-5): AppState.nextWorktreePath — attention-first cyclic worktree selection"
```

---

## Task 2: `GhosttyAction` cases for `next_tab` / `previous_tab`

**Files:**
- Modify: `Sources/GrafttyKit/Keybinds/GhosttyAction.swift`
- Test: `Tests/GrafttyKitTests/Keybinds/GhosttyActionTests.swift`

**Interfaces:**
- Produces: `GhosttyAction.nextTab` (`"next_tab"`), `GhosttyAction.previousTab` (`"previous_tab"`).

- [ ] **Step 1: Update the failing pin test**

In `Tests/GrafttyKitTests/Keybinds/GhosttyActionTests.swift`, add two `#expect`s inside `rawValuesMatchGhosttyConfigSyntax()` (after the `openConfig` line):

```swift
        #expect(GhosttyAction.nextTab.rawValue     == "next_tab")
        #expect(GhosttyAction.previousTab.rawValue == "previous_tab")
```

And bump the count assertion in `allCasesCountMatchesEnumSize()`:

```swift
        #expect(GhosttyAction.allCases.count == 17)
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `swift test --filter GhosttyActionTests`
Expected: FAIL — `type 'GhosttyAction' has no member 'nextTab'`.

- [ ] **Step 3: Add the enum cases**

In `Sources/GrafttyKit/Keybinds/GhosttyAction.swift`, add after `case gotoSplitNext = "goto_split:next"`:

```swift
    case nextTab     = "next_tab"
    case previousTab = "previous_tab"
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `swift test --filter GhosttyActionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Keybinds/GhosttyAction.swift Tests/GrafttyKitTests/Keybinds/GhosttyActionTests.swift
git commit -m "feat(KBD-5): add next_tab/previous_tab GhosttyAction cases"
```

---

## Task 3: UI wiring — FocusedValue + MainWindow + command buttons

This task has no unit test (it is SwiftUI scene/command glue over the already-tested `nextWorktreePath` and `selectWorktree`); it is verified by a clean `swift build`.

**Files:**
- Create: `Sources/Graftty/Views/WorktreeNavFocusedValues.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`

**Interfaces:**
- Consumes: `AppState.nextWorktreePath(forward:)` (Task 1), `GhosttyAction.nextTab` / `.previousTab` (Task 2), `MainWindow.selectWorktree(_:)` (MainWindow.swift:294), `bridgedButton(_:action:onTap:)` (GrafttyApp.swift:3270), `FocusedValues` pattern (AddWorktreeFocusedValues.swift).
- Produces: `FocusedValues.worktreeNavAction: ((Bool) -> Void)?`.

- [ ] **Step 1: Create the FocusedValue key**

Create `Sources/Graftty/Views/WorktreeNavFocusedValues.swift` (mirrors `AddWorktreeFocusedValues.swift`):

```swift
import SwiftUI

/// Scene-scoped command exposed by `MainWindow` so the `.commands` block in
/// `GrafttyApp` (which can't reach view-local state) can drive worktree
/// navigation. The `Bool` is `forward` — `true` for `next_tab`
/// (ctrl+tab), `false` for `previous_tab` (ctrl+shift+tab). A `nil` value
/// means there is nothing to navigate (0/1 selectable worktree), so the
/// menu items are disabled.
struct WorktreeNavActionKey: FocusedValueKey {
    typealias Value = (_ forward: Bool) -> Void
}

extension FocusedValues {
    var worktreeNavAction: ((Bool) -> Void)? {
        get { self[WorktreeNavActionKey.self] }
        set { self[WorktreeNavActionKey.self] = newValue }
    }
}
```

- [ ] **Step 2: Publish the closure from MainWindow**

In `Sources/Graftty/Views/MainWindow.swift`, add a `.focusedSceneValue` next to the existing one (line 150):

```swift
        .focusedSceneValue(\.addWorktreeAction, addWorktreeAction)
        .focusedSceneValue(\.worktreeNavAction, worktreeNavAction)
```

Then add the computed property next to `addWorktreeAction` (near line 220):

```swift
    /// Command handler surfaced to `GrafttyApp.commands` via `@FocusedValue`
    /// for `next_tab` / `previous_tab` (KBD-5). `nil` when there is nothing
    /// to move to, so the menu items disable. Routes through the same
    /// `selectWorktree` sidebar clicks use, so surface show/hide and
    /// `acknowledgeAttention()` all fire identically.
    private var worktreeNavAction: ((Bool) -> Void)? {
        guard appState.nextWorktreePath(forward: true) != nil else { return nil }
        return { forward in
            if let target = appState.nextWorktreePath(forward: forward) {
                selectWorktree(target)
            }
        }
    }
```

Note: the `guard` uses `forward: true` only as a cheap "is there anywhere to go at all?" probe — `nextWorktreePath` returns `nil` for both directions exactly when there are 0/1 selectable worktrees, so either direction works as the enabled-check.

- [ ] **Step 3: Add the command buttons**

In `Sources/Graftty/GrafttyApp.swift`, the nav `CommandGroup` currently ends its pane-nav block at line 460 (`Next Pane`). First add a small `View`-wrapped command pair that can read the focused value (the `.commands` block can't use `@FocusedValue` directly on a bare `Button` closure — mirror how `AddWorktreeCommandButton` is a `View`). Create the buttons as a dedicated view in `WorktreeNavFocusedValues.swift`:

```swift
struct WorktreeNavCommandButtons: View {
    @FocusedValue(\.worktreeNavAction) private var action: ((Bool) -> Void)?
    let nextShortcut: KeyboardShortcut?
    let previousShortcut: KeyboardShortcut?

    var body: some View {
        Group {
            button("Next Worktree", forward: true, shortcut: nextShortcut)
            button("Previous Worktree", forward: false, shortcut: previousShortcut)
        }
    }

    @ViewBuilder
    private func button(_ label: LocalizedStringKey, forward: Bool, shortcut: KeyboardShortcut?) -> some View {
        let b = Button(label) { action?(forward) }.disabled(action == nil)
        if let shortcut { b.keyboardShortcut(shortcut) } else { b }
    }
}
```

Add `import GrafttyKit` at the top of `WorktreeNavFocusedValues.swift` if the file needs it (it does not for the code above, but `LocalizedStringKey`/`KeyboardShortcut` come from `SwiftUI`, already imported).

Then in `GrafttyApp.swift`, inside the nav `CommandGroup`, after line 460 (`Next Pane`) add a divider and the buttons, resolving the chords through the same bridge `bridgedButton` uses:

```swift
                Divider()

                WorktreeNavCommandButtons(
                    nextShortcut: shortcut(for: .nextTab),
                    previousShortcut: shortcut(for: .previousTab)
                )
```

Add a small private helper next to `bridgedButton` (GrafttyApp.swift:3270) that reuses its resolution logic:

```swift
    /// Resolve a `GhosttyAction`'s configured chord to a SwiftUI shortcut,
    /// or nil if unbound — shared by `bridgedButton` and command views that
    /// need the shortcut value directly.
    private func shortcut(for action: GhosttyAction) -> KeyboardShortcut? {
        guard let chord = terminalManager.keybindBridge[action] else { return nil }
        return KeyboardShortcutFromChord.shortcut(from: chord)
    }
```

Optionally refactor `bridgedButton` to call `shortcut(for:)` (DRY) — its body becomes:

```swift
    private func bridgedButton(
        _ label: LocalizedStringKey,
        action: GhosttyAction,
        onTap: @escaping () -> Void
    ) -> some View {
        Group {
            if let shortcut = shortcut(for: action) {
                Button(label, action: onTap).keyboardShortcut(shortcut)
            } else {
                Button(label, action: onTap)
            }
        }
    }
```

- [ ] **Step 4: Build to verify wiring compiles**

Run: `swift build`
Expected: builds with no errors. (If `WorktreeNavCommandButtons` can't see `KeyboardShortcut`/`LocalizedStringKey`, confirm `import SwiftUI` is present.)

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/Views/WorktreeNavFocusedValues.swift Sources/Graftty/Views/MainWindow.swift Sources/Graftty/GrafttyApp.swift
git commit -m "feat(KBD-5): wire ctrl+tab/ctrl+shift+tab to worktree navigation commands"
```

---

## Task 4: Regenerate SPECS.md + full verification

**Files:**
- Modify: `SPECS.md`

- [ ] **Step 1: Regenerate SPECS.md**

Run: `python3 scripts/generate-specs.py` (or `uv run scripts/generate-specs.py` if it needs deps)
Expected: `SPECS.md` updated with the new KBD-5.x entries and no error about duplicate/ambiguous IDs.

- [ ] **Step 2: Verify SPECS.md is consistent**

Run: `python3 scripts/generate-specs.py --check`
Expected: exit 0 (no staleness).

- [ ] **Step 3: Run the full test suite**

Run: `swift test`
Expected: PASS, including `WorktreeNavigationTests` and `GhosttyActionTests`, with no regressions.

- [ ] **Step 4: Commit**

```bash
git add SPECS.md
git commit -m "docs(KBD-5): regenerate SPECS.md for worktree navigation"
```

---

## Self-Review

**Spec coverage:**
- Behavior steps 1–5 → Task 1 (`nextWorktreePath`) + Task 3 (`selectWorktree` routing gives the self-clearing acknowledge).
- Key binding (ctrl+tab / ctrl+shift+tab) → Task 2 (actions) + Task 3 (bridged buttons).
- Edge cases (no selection, 0/1 no-op, current-excluded, wrap, non-on-disk skip, cross-repo) → Task 1 tests KBD-5.4/5.5/5.6 + wrap/flatten cases.
- Requirements KBD-5.1…5.6 → all have `@spec` tests in Task 1. (KBD-5 IDs are introduced directly as real `@Test`s since we implement now; no `KbdTodo.swift` entry is added — consistent with CLAUDE.md's "when implementing now, write the spec directly as a real `@Test` title.")
- SPECS.md regen → Task 4.

**Placeholder scan:** No TBD/TODO; all steps show concrete code and exact commands. The one adaptable spot (`RepoEntry` initializer shape) is called out explicitly in Task 1 Step 1 with instructions, not left vague.

**Type consistency:** `nextWorktreePath(forward:) -> String?` used identically in Task 1 (def), Task 3 (call). `GhosttyAction.nextTab`/`.previousTab` raw values match between Task 2 def and the pin test. `FocusedValues.worktreeNavAction` key/getter names match between the create step and MainWindow's `.focusedSceneValue`. `shortcut(for:)` defined once, used by both the new buttons and the refactored `bridgedButton`.

**Open adapt-at-runtime note:** `RepoEntry` initializer argument labels are assumed as `(path:name:worktrees:)`; Task 1 Step 1 instructs the implementer to confirm and adjust the test helper if the real signature differs. Everything else is pinned to verified signatures.
