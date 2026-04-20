# Allow `/` in worktree and branch names

**Date:** 2026-04-19
**Status:** Approved

## Problem

`WorktreeNameSanitizer` replaces `/` with `-` on every keystroke in the Add
Worktree sheet. This forces common branch conventions (`feature/foo`,
`user/ben/x`, `release/1.2`) into flat names like `feature-foo`, losing the
namespace information that tooling and humans rely on.

## Change

Add `/` to the sanitizer's allowed character set. Nothing else.

## What is deliberately NOT changing

- **No `//` collapse rule.** Unlike `-`, the sanitizer never *produces* `/`
  — only the user types it — so the run-collapse machinery that exists for
  synthesized dashes isn't needed. `foo//bar` passes through the sanitizer
  unchanged; `git worktree add` rejects it and we already surface that
  error in the sheet.
- **No submit-time trim of `/`.** Leading/trailing `/` is rejected by git's
  own ref-format rules; duplicating them client-side means maintaining a
  second copy that can drift.
- **Existing submit-trim behavior is untouched.** `-`, `.`, and whitespace
  continue to be stripped at submit. Those rules match git's own rules
  closely and removing them would only turn clean errors into uglier ones.

## Effect on paths

Worktree paths are built as `<repo>/.worktrees/<name>` in
`MainWindow.swift:339`. With `/` allowed, a worktree named `feature/foo`
produces `<repo>/.worktrees/feature/foo`. `git worktree add` creates the
intermediate `feature/` directory, so no callsite needs to change.

If a user creates both `feature` and `feature/foo` as worktree names, the
second `git worktree add` will fail (can't have a directory and a file at
the same path). That's git's problem to report, not ours to pre-validate.

## Files touched

- `Sources/EspalierKit/Git/WorktreeNameSanitizer.swift` — add `"/"` to
  `isAllowed`.
- `Tests/EspalierKitTests/Git/WorktreeNameSanitizerTests.swift` — replace
  the existing `replacesPathSeparatorWithDash` test (which asserts the old
  behavior) with `preservesPathSeparator`, and add one mixed-input test
  (`"my feature/foo"` → `"my-feature/foo"`) to cover interaction with the
  dash-replacement path.
- `SPECS.md` — update `GIT-5.1`'s allowed-character set to include `/`.
  `GIT-5.3` is unchanged.

## Risks

- **Display names in the sidebar.** `WorktreeEntry.displayName(amongSiblingPaths:)`
  already handles full paths, so a sibling pair like `feature/foo` and
  `feature/bar` will disambiguate the same way any two siblings do. No
  change expected, but worth a visual check after implementation.
- **Dotfile segments.** git rejects ref components that start with `.`
  (e.g. `feature/.foo`). Current submit-trim strips leading `.` from the
  whole ref but not from internal components. We let git surface that
  error — same as today for any other ref-format rule we don't pre-check.
