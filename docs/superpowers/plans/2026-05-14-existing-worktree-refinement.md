# Existing-branch picker refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `BranchComboBox` (popover) with `BranchPicker` (always-visible list + filter), and split `AddWorktreeSheet`'s branch-name state so each mode preserves its prior input across mode toggles.

**Architecture:** Extract the sheet's state into a small `@Observable` `AddWorktreeFormController` so the mode-switch preservation rule (`GIT-5.19`) and the existing-mode submission rule (`GIT-5.18`) are unit-testable. `BranchPicker` is a thin SwiftUI view; its filter/sort/mounted logic lives in the existing `BranchPickerViewModel` (already pure). The auto-select-first-match rule (`GIT-5.17`) is a new pure function on that view-model.

**Tech Stack:** SwiftUI, Swift Testing (`@Test`/`@Suite`), `@Observable` macro, Swift Package Manager (`swift test`).

**Spec:** `docs/superpowers/specs/2026-05-14-existing-worktree-refinement-design.md`

---

## File Structure

**Create:**
- `Sources/Graftty/Views/AddWorktreeFormController.swift` — `@Observable final class` holding the sheet's mutable inputs and derived values (canSubmit, selectedSelection). Pure (no SwiftUI). One file, one responsibility.
- `Sources/Graftty/Views/BranchPicker.swift` — SwiftUI view. Search `TextField` + `List` driven by a `BranchPickerEntry?` selection binding. Calls into `BranchPickerViewModel` for filtering and `BranchPickerViewModel.autoSelect(...)` for the GIT-5.17 rule.
- `Tests/GrafttyTests/Views/AddWorktreeFormControllerTests.swift` — drives the controller directly. Covers GIT-5.18 (canSubmit gate) and GIT-5.19 (mode-switch preservation).
- `Tests/GrafttyTests/Views/BranchPickerAutoSelectTests.swift` — covers GIT-5.17 (auto-select-first / preserve-on-clear).

**Modify:**
- `Sources/Graftty/Views/AddWorktreeSheet.swift` — replace inline `@State` with a single `@State private var controller: AddWorktreeFormController`. Swap `BranchComboBox` callsite for `BranchPicker`. Existing init signature unchanged.
- `Sources/GrafttyKit/Model/BranchPickerViewModel.swift` — add `autoSelect(currentSelection:in:)` pure function.
- `Tests/GrafttyKitTests/Model/BranchPickerViewModelTests.swift` — re-tag the existing "filterText filters by case-insensitive substring on name" test with `@spec GIT-5.16`. (GIT-5.13 keeps the same test; only its EARS text changes — that's done in `SPECS.md` regeneration.)
- `Tests/GrafttyTests/Specs/GitTodo.swift` — add GIT-5.16/5.17/5.18/5.19 inventory entries first, then delete them one-by-one as tests are promoted. (Per CLAUDE.md: inventory entry first; promoted test deletes the inventory line in the same commit.)
- `SPECS.md` — regenerated from annotations by `scripts/generate-specs.py`.
- `Sources/Graftty/Views/SidebarView.swift` — no change needed (`AddWorktreeSheet`'s public init is unchanged).

**Delete:**
- `Sources/Graftty/Views/BranchComboBox.swift` — sole consumer (`AddWorktreeSheet`) no longer references it.

---

### Task 1: Inventory the four new specs (red)

Add `.disabled("not yet implemented")` entries to the GIT-5.x section of `GitTodo.swift`. They'll be deleted as each test is promoted in later tasks.

**Files:**
- Modify: `Tests/GrafttyTests/Specs/GitTodo.swift`

- [ ] **Step 1: Open `Tests/GrafttyTests/Specs/GitTodo.swift` and locate the GIT-5 block.** It ends around the `GIT-5.9` entry. Append the four new entries after `GIT-5.9`:

```swift
    @Test("""
@spec GIT-5.16: While the user is in existing-branch mode, the application shall render a filter `TextField` above the branch list whose contents narrow the list to branches whose name contains the typed substring (case-insensitive).
""", .disabled("not yet implemented"))
    func git_5_16() async throws { }

    @Test("""
@spec GIT-5.17: When the filter text changes and the currently selected branch no longer matches the filter (or no branch is selected), the application shall auto-select the first non-mounted branch in the filtered list. When the filter is cleared, the prior selection shall be preserved if it still exists.
""", .disabled("not yet implemented"))
    func git_5_17() async throws { }

    @Test("""
@spec GIT-5.18: While the user is in existing-branch mode, the Create button shall remain disabled until a branch row is selected; the filter `TextField`'s contents shall not be treated as a freeform branch name.
""", .disabled("not yet implemented"))
    func git_5_18() async throws { }

    @Test("""
@spec GIT-5.19: When the user toggles the branch-mode picker between "New branch" and "Existing branch", the application shall preserve each mode's prior input independently — the new-branch name shall not be clobbered by an existing-branch selection, and an existing-branch selection shall not be cleared by a temporary switch to new-branch mode.
""", .disabled("not yet implemented"))
    func git_5_19() async throws { }
```

- [ ] **Step 2: Build to verify the inventory entries compile.**

Run: `swift build`
Expected: build succeeds; no warnings about the new tests.

- [ ] **Step 3: Commit.**

```bash
git add Tests/GrafttyTests/Specs/GitTodo.swift
git commit -m "test(spec): inventory GIT-5.16..5.19 for existing-branch refinement"
```

---

### Task 2: `BranchPickerViewModel.autoSelect` — pure helper (GIT-5.17)

Add a stateless function: given a current selection and an already-filtered entries list, return what the new selection should be. Keep the current selection if it's still present; otherwise return the first non-mounted entry; otherwise nil.

**Files:**
- Modify: `Sources/GrafttyKit/Model/BranchPickerViewModel.swift`
- Create: `Tests/GrafttyTests/Views/BranchPickerAutoSelectTests.swift`
- Modify: `Tests/GrafttyTests/Specs/GitTodo.swift` (delete the `GIT-5.17` inventory entry)

- [ ] **Step 1: Write the failing test.**

Create `Tests/GrafttyTests/Views/BranchPickerAutoSelectTests.swift`:

```swift
import Testing
import Foundation
import GrafttyProtocol
@testable import GrafttyKit

@Suite("BranchPickerViewModel.autoSelect")
struct BranchPickerAutoSelectTests {

    private func entry(_ name: String, mounted: String? = nil) -> BranchPickerEntry {
        BranchPickerEntry(
            name: name,
            source: .local,
            lastCommitDate: Date(),
            mountedWorktreePath: mounted,
            pr: nil
        )
    }

    @Test("@spec GIT-5.17: When the filter text changes and the currently selected branch no longer matches the filter (or no branch is selected), the application shall auto-select the first non-mounted branch in the filtered list. When the filter is cleared, the prior selection shall be preserved if it still exists.")
    func autoSelectsFirstNonMountedWhenSelectionMissing() {
        let a = entry("alpha")
        let b = entry("beta")
        // No prior selection → picks first.
        #expect(BranchPickerViewModel.autoSelect(currentSelection: nil, in: [a, b])?.name == "alpha")
        // Prior selection no longer in list → picks first.
        let gone = entry("gone")
        #expect(BranchPickerViewModel.autoSelect(currentSelection: gone, in: [a, b])?.name == "alpha")
    }

    @Test func preservesSelectionStillInList() {
        let a = entry("alpha")
        let b = entry("beta")
        #expect(BranchPickerViewModel.autoSelect(currentSelection: b, in: [a, b])?.name == "beta")
    }

    @Test func skipsMountedEntriesWhenChoosingFirst() {
        let mounted = entry("alpha", mounted: "/r/.worktrees/alpha")
        let b = entry("beta")
        #expect(BranchPickerViewModel.autoSelect(currentSelection: nil, in: [mounted, b])?.name == "beta")
    }

    @Test func returnsNilWhenAllEntriesMountedAndNoPrior() {
        let mounted = entry("alpha", mounted: "/r/.worktrees/alpha")
        #expect(BranchPickerViewModel.autoSelect(currentSelection: nil, in: [mounted]) == nil)
    }

    @Test func returnsNilWhenEmpty() {
        #expect(BranchPickerViewModel.autoSelect(currentSelection: nil, in: []) == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `swift test --filter BranchPickerAutoSelectTests`
Expected: FAIL — `BranchPickerViewModel` has no member `autoSelect`.

- [ ] **Step 3: Add the helper to `BranchPickerViewModel.swift`.**

Append the following inside `public enum BranchPickerViewModel { ... }`, before the closing brace:

```swift
    /// Given the user's current selection and a fresh entries list
    /// (already filtered + sorted by `entries(...)`), return what the
    /// selection should become. Keeps the prior selection when it's
    /// still present; otherwise picks the first non-mounted entry;
    /// otherwise nil.
    public static func autoSelect(
        currentSelection: BranchPickerEntry?,
        in entries: [BranchPickerEntry]
    ) -> BranchPickerEntry? {
        if let current = currentSelection, entries.contains(current) {
            return current
        }
        return entries.first(where: { $0.mountedWorktreePath == nil })
    }
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `swift test --filter BranchPickerAutoSelectTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Delete the `GIT-5.17` inventory entry from `GitTodo.swift`.**

Remove the `@Test("""<GIT-5.17 EARS text>""", .disabled(...)) func git_5_17() async throws { }` block added in Task 1.

- [ ] **Step 6: Run the full test suite to confirm no regressions.**

Run: `swift test 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 7: Commit.**

```bash
git add Sources/GrafttyKit/Model/BranchPickerViewModel.swift Tests/GrafttyTests/Views/BranchPickerAutoSelectTests.swift Tests/GrafttyTests/Specs/GitTodo.swift
git commit -m "feat(GIT-5.17): auto-select first non-mounted branch on filter change"
```

---

### Task 3: Promote GIT-5.16 (filter substring rule)

`BranchPickerViewModelTests` already has a test named `filtersByText` that exercises the case-insensitive substring filter on `entries(filterText:)`. Re-tag it with the `@spec GIT-5.16` text and delete the inventory entry.

**Files:**
- Modify: `Tests/GrafttyKitTests/Model/BranchPickerViewModelTests.swift`
- Modify: `Tests/GrafttyTests/Specs/GitTodo.swift` (delete the `GIT-5.16` inventory entry)

- [ ] **Step 1: Open `Tests/GrafttyKitTests/Model/BranchPickerViewModelTests.swift`. Replace the `@Test("filterText filters by case-insensitive substring on name")` line above `func filtersByText()` with the spec-tagged version:**

```swift
    @Test("@spec GIT-5.16: While the user is in existing-branch mode, the application shall render a filter `TextField` above the branch list whose contents narrow the list to branches whose name contains the typed substring (case-insensitive).")
    func filtersByText() {
```

Body of `filtersByText` stays exactly as it is (lines 83-89 of the current file).

- [ ] **Step 2: Run the test to verify it still passes with the new title.**

Run: `swift test --filter BranchPickerViewModelTests.filtersByText`
Expected: PASS.

- [ ] **Step 3: Delete the `GIT-5.16` inventory entry from `GitTodo.swift`.**

- [ ] **Step 4: Commit.**

```bash
git add Tests/GrafttyKitTests/Model/BranchPickerViewModelTests.swift Tests/GrafttyTests/Specs/GitTodo.swift
git commit -m "test(GIT-5.16): tag existing filter-substring test with spec ID"
```

---

### Task 4: `AddWorktreeFormController` skeleton + canSubmit (GIT-5.18)

Extract the sheet's `@State` into an `@Observable` class. This makes the submit-gate and mode-switch rules unit-testable, and gives the View a single state object instead of seven `@State` properties.

**Files:**
- Create: `Sources/Graftty/Views/AddWorktreeFormController.swift`
- Create: `Tests/GrafttyTests/Views/AddWorktreeFormControllerTests.swift`
- Modify: `Tests/GrafttyTests/Specs/GitTodo.swift` (delete the `GIT-5.18` inventory entry)

- [ ] **Step 1: Write the failing test.**

Create `Tests/GrafttyTests/Views/AddWorktreeFormControllerTests.swift`:

```swift
import Testing
import Foundation
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@Suite("AddWorktreeFormController")
struct AddWorktreeFormControllerTests {

    private func someEntry(name: String = "feat") -> BranchPickerEntry {
        BranchPickerEntry(
            name: name,
            source: .local,
            lastCommitDate: Date(),
            mountedWorktreePath: nil,
            pr: nil
        )
    }

    @Test func newBranchModeRequiresWorktreeNameAndBranchName() {
        let c = AddWorktreeFormController(initialWorktreeName: "")
        #expect(c.canSubmit == false)  // empty worktree name
        c.worktreeName = "wt"
        c.newBranchName = "wt"
        #expect(c.canSubmit == true)
    }

    @Test("@spec GIT-5.18: While the user is in existing-branch mode, the Create button shall remain disabled until a branch row is selected; the filter `TextField`'s contents shall not be treated as a freeform branch name.")
    func existingBranchModeRequiresSelection() {
        let c = AddWorktreeFormController(initialWorktreeName: "wt")
        c.branchMode = .existing
        #expect(c.canSubmit == false)  // no selection yet
        c.pickExistingBranch(someEntry(name: "feat"))
        #expect(c.canSubmit == true)
        #expect(c.selectedSelection == .useExisting(name: "feat", source: .local))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `swift test --filter AddWorktreeFormControllerTests`
Expected: FAIL — `AddWorktreeFormController` doesn't exist.

- [ ] **Step 3: Create `Sources/Graftty/Views/AddWorktreeFormController.swift`:**

```swift
import Foundation
import Observation
import GrafttyKit
import GrafttyProtocol

/// State holder for `AddWorktreeSheet`. Owns the user's inputs across
/// both branch modes (`newBranchName` for "New branch", `existingSelection`
/// for "Existing branch") and the mirroring flags that drive auto-fill
/// between worktree name and branch name. Keeping each mode's input in
/// its own field is what makes `GIT-5.19` (mode-switch preservation)
/// true by construction — toggling `branchMode` doesn't touch either.
@Observable
public final class AddWorktreeFormController {
    public enum BranchMode: Hashable { case newBranch, existing }

    public var worktreeName: String
    public var branchMode: BranchMode = .newBranch
    public var newBranchName: String
    public var existingSelection: BranchPickerEntry?

    /// Tracks whether the branch field is still mirroring the worktree
    /// name. Once the user types something different in the branch field
    /// (in `.newBranch` mode), we stop auto-syncing.
    public var branchMirrorsWorktree: Bool = true

    /// @spec GIT-5.15: tracks whether the worktree name still mirrors
    /// the selected existing branch.
    public var worktreeMirrorsBranch: Bool = true

    public init(initialWorktreeName: String) {
        self.worktreeName = initialWorktreeName
        self.newBranchName = initialWorktreeName
    }

    /// Called by the View when the existing-branch picker reports a
    /// selection. Mirrors the prior popover-tap behavior in
    /// `BranchComboBox`.
    public func pickExistingBranch(_ entry: BranchPickerEntry) {
        existingSelection = entry
        if worktreeMirrorsBranch {
            worktreeName = entry.name
        }
    }

    public var canSubmit: Bool {
        guard !WorktreeNameSanitizer.trimForSubmit(worktreeName).isEmpty else {
            return false
        }
        return selectedSelection != nil
    }

    public var selectedSelection: BranchSelection? {
        switch branchMode {
        case .newBranch:
            let trimmed = WorktreeNameSanitizer.trimForSubmit(newBranchName)
            return trimmed.isEmpty ? nil : .createNew(name: trimmed)
        case .existing:
            guard let entry = existingSelection else { return nil }
            return .useExisting(name: entry.name, source: entry.source)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `swift test --filter AddWorktreeFormControllerTests`
Expected: PASS, 2 tests.

- [ ] **Step 5: Delete the `GIT-5.18` inventory entry from `GitTodo.swift`.**

- [ ] **Step 6: Commit.**

```bash
git add Sources/Graftty/Views/AddWorktreeFormController.swift Tests/GrafttyTests/Views/AddWorktreeFormControllerTests.swift Tests/GrafttyTests/Specs/GitTodo.swift
git commit -m "feat(GIT-5.18): AddWorktreeFormController + selection-required submit gate"
```

---

### Task 5: Mode-switch state preservation (GIT-5.19)

Verify that toggling `branchMode` preserves both modes' inputs independently. No production code change needed if Task 4 was done right — this task adds the spec test that locks the invariant in.

**Files:**
- Modify: `Tests/GrafttyTests/Views/AddWorktreeFormControllerTests.swift`
- Modify: `Tests/GrafttyTests/Specs/GitTodo.swift` (delete the `GIT-5.19` inventory entry)

- [ ] **Step 1: Append to `AddWorktreeFormControllerTests.swift` (inside the `@Suite`):**

```swift
    @Test("@spec GIT-5.19: When the user toggles the branch-mode picker between \"New branch\" and \"Existing branch\", the application shall preserve each mode's prior input independently — the new-branch name shall not be clobbered by an existing-branch selection, and an existing-branch selection shall not be cleared by a temporary switch to new-branch mode.")
    func modeSwitchPreservesEachModesInputIndependently() {
        let c = AddWorktreeFormController(initialWorktreeName: "")
        c.worktreeName = "my-worktree"
        c.newBranchName = "cool-thing-v2"   // user customized
        c.branchMirrorsWorktree = false

        // New → Existing → pick a branch.
        c.branchMode = .existing
        c.pickExistingBranch(someEntry(name: "feat-other"))
        #expect(c.newBranchName == "cool-thing-v2", "new-branch name must survive the mode switch")

        // Existing → New: new-branch name is still there.
        c.branchMode = .newBranch
        #expect(c.newBranchName == "cool-thing-v2")
        #expect(c.selectedSelection == .createNew(name: "cool-thing-v2"))

        // New → Existing again: prior pick is still there.
        c.branchMode = .existing
        #expect(c.existingSelection?.name == "feat-other")
        #expect(c.selectedSelection == .useExisting(name: "feat-other", source: .local))
    }
```

- [ ] **Step 2: Run the test to verify it passes.** (Should pass on the first run — Task 4's structure already enforces this.)

Run: `swift test --filter AddWorktreeFormControllerTests`
Expected: PASS, 3 tests.

- [ ] **Step 3: Delete the `GIT-5.19` inventory entry from `GitTodo.swift`.**

- [ ] **Step 4: Commit.**

```bash
git add Tests/GrafttyTests/Views/AddWorktreeFormControllerTests.swift Tests/GrafttyTests/Specs/GitTodo.swift
git commit -m "test(GIT-5.19): mode-switch preserves each mode's input independently"
```

---

### Task 6: `BranchPicker` view

The new SwiftUI view. Search `TextField` on top, scrolling `List` below, selection bound to a `BranchPickerEntry?`. Wires GIT-5.16 (filter via `BranchPickerViewModel.entries(...)`) and GIT-5.17 (auto-select via `BranchPickerViewModel.autoSelect(...)`) into the UI.

**Files:**
- Create: `Sources/Graftty/Views/BranchPicker.swift`

- [ ] **Step 1: Create the file with this content:**

```swift
import SwiftUI
import GrafttyKit

/// Always-visible branch list with a filter `TextField` on top. The
/// search text is internal state; the parent sees only the typed
/// `selection`. Mounted entries are dimmed and unselectable.
///
/// @spec GIT-5.13, GIT-5.16, GIT-5.17, GIT-5.18
struct BranchPicker: View {
    let entries: [BranchPickerEntry]
    @Binding var selection: BranchPickerEntry?
    let onCommit: () -> Void

    @State private var filter: String = ""
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Filter branches", text: $filter)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .onSubmit { onCommit() }

            List(selection: selectionBinding) {
                ForEach(filteredEntries, id: \.self) { entry in
                    row(for: entry)
                        .tag(Optional(entry))
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(maxHeight: 180)
        }
        .onChange(of: filter) { _, _ in
            applyAutoSelect()
        }
        .onAppear {
            filterFocused = true
            // Don't auto-select on appear: GIT-5.19 requires that
            // switching to existing-branch mode doesn't side-effect
            // worktreeName via pickExistingBranch. Auto-select fires
            // when the user types into the filter (GIT-5.17).
        }
    }

    private var filteredEntries: [BranchPickerEntry] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.name.lowercased().contains(needle) }
    }

    /// Wraps `selection` to reject taps on mounted rows.
    private var selectionBinding: Binding<BranchPickerEntry?> {
        Binding(
            get: { selection },
            set: { new in
                if let new, new.mountedWorktreePath != nil { return }
                selection = new
            }
        )
    }

    private func applyAutoSelect() {
        selection = BranchPickerViewModel.autoSelect(
            currentSelection: selection,
            in: filteredEntries
        )
    }

    @ViewBuilder
    private func row(for entry: BranchPickerEntry) -> some View {
        let mountedPath = entry.mountedWorktreePath
        let mounted = mountedPath != nil
        HStack(spacing: 8) {
            Text(entry.name)
                .font(.callout)
                .strikethrough(mounted)
                .lineLimit(1)
            if let mountedPath {
                Text("in worktree \((mountedPath as NSString).lastPathComponent)")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let pr = entry.pr {
                Text("#\(pr.number) · \(pr.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Text(Self.relativeFormatter.localizedString(for: entry.lastCommitDate, relativeTo: Date()))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
        .opacity(mounted ? 0.5 : 1)
        .allowsHitTesting(!mounted)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
```

- [ ] **Step 2: Build to verify it compiles.**

Run: `swift build`
Expected: success. (No tests yet — `BranchPicker` is a pure view; its underlying logic is covered by `BranchPickerAutoSelectTests` and `BranchPickerViewModelTests`.)

- [ ] **Step 3: Commit.**

```bash
git add Sources/Graftty/Views/BranchPicker.swift
git commit -m "feat: add BranchPicker (search + always-visible list)"
```

---

### Task 7: Swap `AddWorktreeSheet` to controller + `BranchPicker`; delete `BranchComboBox`

Replace the sheet's seven `@State` properties with a single `@State controller`. Swap the `BranchComboBox` callsite for `BranchPicker`. Delete `BranchComboBox.swift`. Update `GIT-5.15`'s annotation site if needed.

**Files:**
- Modify: `Sources/Graftty/Views/AddWorktreeSheet.swift`
- Delete: `Sources/Graftty/Views/BranchComboBox.swift`

- [ ] **Step 1: Rewrite `Sources/Graftty/Views/AddWorktreeSheet.swift`. Replace the whole file with:**

```swift
import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol

/// Sheet for creating a new worktree under a repo. Collects a directory
/// name (used for the worktree path at `<repo>/.worktrees/<name>`) and a
/// branch selection: either a fresh branch name (mirrors the worktree
/// name until edited independently) or an existing branch picked from
/// `BranchPicker`. State lives in `AddWorktreeFormController` so each
/// mode's input survives mode toggles (`GIT-5.19`).
struct AddWorktreeSheet: View {
    typealias BranchMode = AddWorktreeFormController.BranchMode

    let repoDisplayName: String
    let initialWorktreeName: String
    let branchEntries: [BranchPickerEntry]
    let onSubmit: (String, BranchSelection) async -> String?
    let onCancel: () -> Void

    @State private var controller: AddWorktreeFormController
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    @FocusState private var worktreeFieldFocused: Bool

    init(
        repoDisplayName: String,
        initialWorktreeName: String = "",
        branchEntries: [BranchPickerEntry] = [],
        onSubmit: @escaping (String, BranchSelection) async -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.repoDisplayName = repoDisplayName
        self.initialWorktreeName = initialWorktreeName
        self.branchEntries = branchEntries
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _controller = State(initialValue: AddWorktreeFormController(initialWorktreeName: initialWorktreeName))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Worktree to \(repoDisplayName)")
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Worktree name:")
                        .foregroundStyle(.secondary)
                    TextField("feature-xyz", text: $controller.worktreeName)
                        .textFieldStyle(.roundedBorder)
                        .focused($worktreeFieldFocused)
                        .onChange(of: controller.worktreeName) { _, new in
                            let sanitized = WorktreeNameSanitizer.sanitize(new)
                            if sanitized != new {
                                controller.worktreeName = sanitized
                                return
                            }
                            if controller.branchMode == .newBranch && controller.branchMirrorsWorktree {
                                controller.newBranchName = sanitized
                            }
                            if controller.branchMode == .existing,
                               let selName = controller.existingSelection?.name,
                               sanitized != selName {
                                controller.worktreeMirrorsBranch = false
                            }
                        }
                }
                GridRow {
                    Text("Branch:")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $controller.branchMode) {
                            Text("New branch").tag(BranchMode.newBranch)
                            Text("Existing branch").tag(BranchMode.existing)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if controller.branchMode == .newBranch {
                            TextField("feature-xyz", text: $controller.newBranchName)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: controller.newBranchName) { _, new in
                                    let sanitized = WorktreeNameSanitizer.sanitize(new)
                                    if sanitized != new {
                                        controller.newBranchName = sanitized
                                        return
                                    }
                                    if sanitized != controller.worktreeName {
                                        controller.branchMirrorsWorktree = false
                                    }
                                }
                        } else {
                            BranchPicker(
                                entries: branchEntries,
                                selection: Binding(
                                    get: { controller.existingSelection },
                                    set: { new in
                                        if let new {
                                            controller.pickExistingBranch(new)
                                        } else {
                                            controller.existingSelection = nil
                                        }
                                    }
                                ),
                                onCommit: { Task { await submit() } }
                            )
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canSubmit || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            worktreeFieldFocused = true
            if !initialWorktreeName.isEmpty {
                DispatchQueue.main.async {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
        }
    }

    private func submit() async {
        guard let selection = controller.selectedSelection else { return }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        let wt = WorktreeNameSanitizer.trimForSubmit(controller.worktreeName)
        if let err = await onSubmit(wt, selection) {
            errorMessage = err
        }
    }
}
```

- [ ] **Step 2: Delete `Sources/Graftty/Views/BranchComboBox.swift`.**

Run: `git rm Sources/Graftty/Views/BranchComboBox.swift`

- [ ] **Step 3: Build to verify no callers reference `BranchComboBox`.**

Run: `swift build 2>&1 | tail -30`
Expected: success. If a "cannot find 'BranchComboBox' in scope" error appears, grep for the caller and update it — but `SidebarView.swift` only uses `AddWorktreeSheet`, which doesn't change its public init.

- [ ] **Step 4: Run the full test suite.**

Run: `swift test 2>&1 | tail -30`
Expected: all tests pass.

- [ ] **Step 5: Manual smoke check.**

Run: `swift run Graftty`
Click "+" on a repo to open the Add Worktree sheet. Verify:
- "New branch" mode behaves as before (worktree+branch fields, mirroring).
- "Existing branch" mode shows the filter `TextField` on top and an always-visible list below.
- Typing in the filter narrows the list. The first non-mounted match is auto-highlighted.
- Clicking a mounted row does nothing.
- Switching New → Existing → New restores the original new-branch name.
- "Create" is disabled in existing-branch mode until a row is selected.

Close the app. (No need to keep it running.)

- [ ] **Step 6: Commit.**

```bash
git add Sources/Graftty/Views/AddWorktreeSheet.swift Sources/Graftty/Views/BranchComboBox.swift
git commit -m "feat(GIT-5.13): replace BranchComboBox with always-visible BranchPicker"
```

---

### Task 8: Regenerate `SPECS.md`

GIT-5.13's amended text and the four new spec annotations must be reflected in `SPECS.md`. The generator pulls EARS text from `@spec` annotations.

**Files:**
- Modify: `SPECS.md` (regenerated)

- [ ] **Step 1: Update GIT-5.13's annotation site.** The amended text is now:

> While the user is in existing-branch mode, the application shall display branches sorted by last-commit date descending in an always-visible list, with branches mounted in another worktree dimmed and unselectable.

Open `Tests/GrafttyKitTests/Model/BranchPickerViewModelTests.swift` and replace the existing `GIT-5.13` `@Test(...)` title with:

```swift
    @Test("@spec GIT-5.13: While the user is in existing-branch mode, the application shall display branches sorted by last-commit date descending in an always-visible list, with branches mounted in another worktree dimmed and unselectable.")
    func sortsByDateDesc() {
```

- [ ] **Step 2: Run the generator.**

Run: `scripts/generate-specs.py`
Expected: writes `SPECS.md`. No error.

- [ ] **Step 3: Verify `SPECS.md` reflects the changes.**

Run: `grep -A 2 "GIT-5.13\|GIT-5.16\|GIT-5.17\|GIT-5.18\|GIT-5.19" SPECS.md`
Expected: GIT-5.13 shows the amended ("always-visible list") text; GIT-5.16/5.17/5.18/5.19 each appear with their EARS text.

- [ ] **Step 4: Run the spec-generation check (mirrors CI).**

Run: `scripts/generate-specs.py --check`
Expected: success (no diff).

- [ ] **Step 5: Run the full test suite once more.**

Run: `swift test 2>&1 | tail -10`
Expected: all tests pass.

- [ ] **Step 6: Commit.**

```bash
git add Tests/GrafttyKitTests/Model/BranchPickerViewModelTests.swift SPECS.md
git commit -m "docs(spec): regenerate SPECS.md for GIT-5.13 amend + 5.16..5.19"
```

---

### Task 9: `/simplify` review

CLAUDE.md requires running `/simplify` before opening a PR. Per the saved feedback memory, run it after subagents finish and before the PR.

- [ ] **Step 1: Invoke the simplify skill on the changed code.**

Run the `simplify` skill (in-conversation, not a subagent). Scope: all files modified in Tasks 1–8 on this branch. Apply any improvements it surfaces. If it surfaces non-trivial changes that would expand scope, ask the user before applying.

- [ ] **Step 2: Re-run the test suite if `/simplify` made any changes.**

Run: `swift test 2>&1 | tail -10`
Expected: all tests pass.

- [ ] **Step 3: Commit any /simplify changes.** (If none, skip.)

```bash
git add -u
git commit -m "refactor: /simplify pass"
```

---

### Task 10: Open the PR

- [ ] **Step 1: Push the branch.**

Run: `git push -u origin existing-worktree-refinement`

- [ ] **Step 2: Create the PR.**

Run:

```bash
gh pr create --title "feat(worktree): always-visible branch picker + mode-switch state preservation (GIT-5.13, 5.16..5.19)" --body "$(cat <<'EOF'
## Summary

- Replaces the existing-branch popover (`BranchComboBox`) with an inline `BranchPicker`: search `TextField` on top, always-visible scrolling list below. Selection is required to submit (no freeform-typed-name fallback).
- Splits `AddWorktreeSheet`'s branch state across modes via a new `AddWorktreeFormController` (`@Observable`), so switching New → Existing → New restores the user's previously typed new-branch name.
- Amends `GIT-5.13`; adds `GIT-5.16` (filter substring), `GIT-5.17` (auto-select first non-mounted on filter change), `GIT-5.18` (selection-required submit), `GIT-5.19` (mode-switch input preservation).

## Test plan

- [ ] `swift test` is green.
- [ ] `scripts/generate-specs.py --check` is green.
- [ ] Manual: open Add Worktree sheet, type in existing-branch filter, observe auto-highlight on first non-mounted match.
- [ ] Manual: type "foo" in New branch → switch to Existing → switch back → field still shows "foo".
- [ ] Manual: in Existing branch with no row selected, Create is disabled.

Spec: `docs/superpowers/specs/2026-05-14-existing-worktree-refinement-design.md`
Plan: `docs/superpowers/plans/2026-05-14-existing-worktree-refinement.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Print PR URL. Confirm CI.** Wait for CI to complete; investigate any failures.
