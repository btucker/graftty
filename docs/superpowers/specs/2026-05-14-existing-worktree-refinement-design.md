# Existing-branch picker refinement

**Date:** 2026-05-14
**Status:** Approved

## Problem

PR #160 added an "Existing branch" mode to the Add Worktree sheet, presented as a `BranchComboBox`: a single `TextField` that opens a popover with matching branches. Two rough edges have emerged:

1. **The popover is fiddly.** It opens on focus, closes on selection, and the typed text doubles as both filter and submitted value. The freeform-typed-name path falls through to `BranchSelection(.local)` by guessing whether the typed string matches the entry list at submit time (`AddWorktreeSheet.swift:174-176`). It's the kind of code that works until it doesn't.

2. **Mode switches lose the user's typing.** `AddWorktreeSheet` uses one `branchName` `@State` for both modes. Typing a new-branch name, switching to "Existing branch", picking a branch, and switching back to "New branch" replaces the originally typed name with the picked branch.

## Change

Replace `BranchComboBox` with `BranchPicker`: a search `TextField` over an always-visible scrolling list. Selection is a typed `BranchPickerEntry?`, never a string match. Split `AddWorktreeSheet`'s state so each mode keeps its own input across mode toggles.

## Component shape

`BranchPicker` is the only consumer of `BranchPickerEntry` in the Views layer. `BranchComboBox` is deleted, not deprecated.

```swift
struct BranchPicker: View {
    let entries: [BranchPickerEntry]
    @Binding var selection: BranchPickerEntry?   // nil until user picks
    let onCommit: () -> Void                      // Return-to-create
}
```

Internal state:

- `@State private var filter: String = ""` — search text. Owned by the picker; the parent never reads or persists it. (Filter text is transient UI state, not part of the create request.)
- The list uses SwiftUI `List(filteredEntries, selection: $selection)` so arrow-key navigation works natively.
- An `onChange(of: filter)` applies the auto-select-first rule (`GIT-5.17`): if the current `selection` no longer matches the filter — or is `nil` — set `selection` to the first non-mounted match. If the filter is cleared, the prior selection is preserved if it still exists in the unfiltered list.
- Mounted entries (`entry.mountedWorktreePath != nil`) stay dimmed + strikethrough, are skipped by auto-select, and are unselectable via arrow navigation.
- The search `TextField` receives initial focus the first time the segmented picker enters `.existing` mode.

## AddWorktreeSheet state changes

The single shared `@State private var branchName` is split:

```swift
// new-branch mode only
@State private var newBranchName: String       // init to initialWorktreeName
@State private var branchMirrorsWorktree: Bool

// existing-branch mode only
@State private var existingSelection: BranchPickerEntry?
@State private var worktreeMirrorsBranch: Bool  // GIT-5.15 (unchanged)
```

`branchMode` no longer touches either piece of state when it flips. A typed new-branch name stays parked in `newBranchName`; an existing-branch pick stays parked in `existingSelection`. This satisfies `GIT-5.19` by construction — no explicit "stash on switch / restore on switch" logic is needed.

`selectedSelection` becomes optional and type-safe:

```swift
private var selectedSelection: BranchSelection? {
    switch branchMode {
    case .newBranch:
        let trimmed = WorktreeNameSanitizer.trimForSubmit(newBranchName)
        return trimmed.isEmpty ? nil : .createNew(name: trimmed)
    case .existing:
        guard let entry = existingSelection else { return nil }
        return .useExisting(name: entry.name, source: entry.source)
    }
}
```

`canSubmit` becomes `selectedSelection != nil && !WorktreeNameSanitizer.trimForSubmit(worktreeName).isEmpty`. In existing-branch mode the Create button is disabled until a row is selected — no freeform fallback path (`GIT-5.18`).

`GIT-5.15` (auto-fill worktree name on selection) fires from the picker's `selection` binding's `onChange`, replacing the popover-row `.onTapGesture` trigger. Same effect; same `worktreeMirrorsBranch` gate.

## Specs

### Amended

**GIT-5.13** — text becomes:
> While the user is in existing-branch mode, the application shall display branches sorted by last-commit date descending in an always-visible list, with branches mounted in another worktree dimmed and unselectable.

### New

- **GIT-5.16** — While the user is in existing-branch mode, the application shall render a filter `TextField` above the branch list whose contents narrow the list to branches whose name contains the typed substring (case-insensitive).

- **GIT-5.17** — When the filter text changes and the currently selected branch no longer matches the filter (or no branch is selected), the application shall auto-select the first non-mounted branch in the filtered list. When the filter is cleared, the prior selection shall be preserved if it still exists.

- **GIT-5.18** — While the user is in existing-branch mode, the Create button shall remain disabled until a branch row is selected; the filter `TextField`'s contents shall not be treated as a freeform branch name.

- **GIT-5.19** — When the user toggles the branch-mode picker between "New branch" and "Existing branch", the application shall preserve each mode's prior input independently — the new-branch name shall not be clobbered by an existing-branch selection, and an existing-branch selection shall not be cleared by a temporary switch to new-branch mode.

`GIT-5.10`, `5.11`, `5.12`, `5.14`, `5.15` carry over unchanged.

## Files touched

- `Sources/Graftty/Views/BranchComboBox.swift` — **deleted**.
- `Sources/Graftty/Views/BranchPicker.swift` — **new**. Search field + always-visible list as described above.
- `Sources/Graftty/Views/AddWorktreeSheet.swift` — split `branchName` state; swap `BranchComboBox` callsite for `BranchPicker`; update `selectedSelection` / `canSubmit`.
- `Tests/GrafttyTests/AddWorktreeSheetTests.swift` (or a new `BranchPickerTests.swift`) — promote the four new `@spec` entries from `GitTodo.swift` to real `@Test`s; update `GIT-5.13`'s test to match amended phrasing.
- `Tests/GrafttyTests/Specs/GitTodo.swift` — add `GIT-5.16`/`5.17`/`5.18`/`5.19` inventory entries first (red), then delete them as their tests are promoted (per CLAUDE.md spec workflow).
- `SPECS.md` — regenerated via `scripts/generate-specs.py`.

## What is deliberately NOT changing

- **`BranchPickerEntry` and `BranchSelection`** are unchanged. The protocol payload and the GitWorktreeAdd argv switching stay as-is.
- **`GIT-5.15`** (worktree-name auto-fill on selection) keeps its current text. Only the trigger plumbing changes.
- **Sheet width** stays at 460pt. Sheet height grows by the list's height (cap the list at ~180pt scroll-area) — `.frame(width: 460)` already lets vertical extent flow.
- **No freeform-branch shortcut.** Users who want to create a worktree off a name git would resolve as `origin/<name>` must wait for that branch to appear in the picker. This matches the user's "you should have to select what you want" direction and removes the guess-at-submit-time fallback.

## Testing

Per the CLAUDE.md RED/GREEN workflow: inventory entries land in `GitTodo.swift` first, then promote to real `@Test`s in a `*Tests.swift` file with the EARS text in the title. `swift test` is the gate; iOS-only flows aren't involved here so macOS CI is sufficient. `scripts/generate-specs.py` regenerates `SPECS.md`; commit the regenerated file alongside the code change.
