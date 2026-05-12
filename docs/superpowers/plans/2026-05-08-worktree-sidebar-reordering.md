# Worktree Sidebar Reordering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users drag worktrees within a project sidebar section, persist that order, and permanently move stale/yellow worktrees to the bottom of that project.

**Architecture:** Persisted order remains the existing `RepoEntry.worktrees` array. `AppState` owns manual reordering and stale-last normalization helpers; `WorktreeReconciler` applies stale-last ordering after discovery merges; `SidebarView` wires SwiftUI row moves to the model helper.

**Tech Stack:** Swift, SwiftUI `List`/`ForEach.onMove`, Swift Testing, existing `AppState` JSON persistence.

---

### Task 1: Model Ordering Helpers

**Files:**
- Modify: `Sources/GrafttyKit/Model/AppState.swift`
- Test: `Tests/GrafttyKitTests/Model/AppStateTests.swift`

- [ ] Write failing tests for moving worktrees within one repo, rejecting cross-repo/no-op inputs, and stable stale-last normalization.
- [ ] Run `swift test --filter AppStateTests` and confirm the new tests fail.
- [ ] Add `AppState.moveWorktrees(inRepoID:fromOffsets:toOffset:)` and `AppState.moveStaleWorktreesToBottom(inRepoID:)`.
- [ ] Run `swift test --filter AppStateTests` and confirm the tests pass.

### Task 2: Reconciler Stale Ordering

**Files:**
- Modify: `Sources/GrafttyKit/Git/WorktreeReconciler.swift`
- Test: `Tests/GrafttyKitTests/Git/WorktreeReconcilerTests.swift`

- [ ] Write a failing test proving a newly-stale worktree is moved after non-stale siblings while preserving relative order.
- [ ] Run `swift test --filter WorktreeReconcilerTests` and confirm the new test fails.
- [ ] Apply stale-last normalization to the reconciler result before returning.
- [ ] Run `swift test --filter WorktreeReconcilerTests` and confirm the tests pass.

### Task 3: Sidebar Drag Wiring and Specs

**Files:**
- Modify: `Sources/Graftty/Views/SidebarView.swift`
- Modify: `Tests/GrafttyTests/Specs/LayoutTodo.swift` or existing active spec tests
- Generated: `SPECS.md`

- [ ] Add `@spec` coverage for drag reorder and stale-bottom behavior.
- [ ] Attach `.onMove` to each repository section's worktree `ForEach` and call the `AppState` helper.
- [ ] Run targeted Swift tests, then `swift test`.
- [ ] Run `scripts/generate-specs.py` and verify `SPECS.md` is current.
