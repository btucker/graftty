# Add non-git repositories to Graftty

**Status:** Draft — design approved 2026-05-11
**Branch:** `add-non-git-repos`

## Problem

Add Repository today refuses any folder that isn't already a git repo or worktree, with a single "Not a Git Repository" warning. Users who want to manage a non-git project folder in Graftty — to get panes, terminals, attention, teams, pane-control, drag-reorder, etc. — have no way in. Some users would prefer to `git init` the folder up-front; others want to keep the folder untouched and just use Graftty's pane/terminal/team features.

## Goals

- Allow adding a folder that contains no `.git` entry, either by initializing git on the spot or by adding the folder as-is.
- Reuse existing codepaths. Non-git repos render through the same sidebar, panes, terminals, attention, drag-reorder, teams, pane-control, persistence, web/iOS bridge, and CLI as git-tracked repos.
- Hide git-only affordances (Add Worktree, Delete Worktree, PR-merged offers) on non-git repos; skip per-repo git polling (PR status, remote branches, git status).
- Allow promoting a non-git repo to git-tracked later from the repo's context menu.
- Preserve existing `state.json` blobs — pre-feature entries decode as git-tracked.

## Non-goals

- Importing existing files into the initial git commit. The "Initialize Git Repository" path creates an empty commit only; staging the working tree is the user's decision.
- Reverting a git-tracked repo to non-git from inside Graftty.
- Building a non-git equivalent of `git worktree add` (sub-projects under one folder). A non-git repo has exactly one "worktree" — the project folder itself.

## Approach (selected)

A single boolean flag on `RepoEntry` plus one discovery facade. A non-git repo is a normal `RepoEntry` with one normal `WorktreeEntry` whose `path == repo.path` and `branch == "main"`. Every reconcile call site goes through a new `WorktreeDiscovery` facade that dispatches to either `GitWorktreeDiscovery.discover` or a synthetic single-entry result.

Alternatives rejected:

- **Implicit detection** (no flag, probe `.git` at every git callsite) — fragile and forces every git callsite to learn the check.
- **Separate `ProjectEntry` type** — most type-safe but introduces a parallel hierarchy, directly contradicting the reuse-codepaths constraint.

## Design

### 1. Model change — `RepoEntry.isGitTracked`

Add one field:

```swift
public struct RepoEntry: ... {
    // ...existing fields...
    public var isGitTracked: Bool
}
```

- New init parameter defaults to `true` so call sites don't change.
- `init(from:)` adds `isGitTracked = try container.decodeIfPresent(Bool.self, forKey: .isGitTracked) ?? true`. Pre-feature `state.json` blobs load unchanged.
- A non-git `RepoEntry` always carries exactly **one** `WorktreeEntry` with `path == repo.path` and `branch == "main"` (literal). The `WorktreeEntry`'s state field is unconstrained — `.closed`/`.running` follow pane activity, same as a git worktree.

### 2. Add-path UX

When the user picks a folder via Add Repository (menu, sidebar `+`, or drag-and-drop):

1. `GitRepoDetector.detect(path:)` runs unchanged.
2. On `.repoRoot` / `.worktree` — existing behavior, untouched.
3. On `.notARepo` — replace today's "Not a Git Repository" warning with a three-button choice alert:
   - **"Initialize Git Repository"** (default) — runs `git init` then `git commit --allow-empty -m "Initial commit"` in the folder, then re-enters the existing `.repoRoot` flow (so discovery, bookmark mint, reconciler all run unchanged).
   - **"Add Without Git"** — constructs a non-git `RepoEntry` directly and calls `appState.addRepo(_:)`. Bookmark is still minted (rename/relocate recovery in LAYOUT-4.x doesn't care about `.git`).
   - **"Cancel"** — bail.

The same alert is shared between the menu/`+` path and the drag-and-drop `addPath` entry point.

A small `GitInit` helper encapsulates `git init` + empty commit. Failures surface via the same alert style as `GitWorktreeRemove.Error`. The Initialize path on a permission-denied folder shows an error alert and aborts; it does not silently degrade to "Add Without Git".

### 3. Discovery facade

```swift
public enum WorktreeDiscovery {
    public static func discover(repo: RepoEntry) async throws -> [DiscoveredWorktree] {
        if repo.isGitTracked {
            return try await GitWorktreeDiscovery.discover(repoPath: repo.path)
        }
        return [DiscoveredWorktree(path: repo.path, branch: "main")]
    }
}
```

Migrate three call sites from `GitWorktreeDiscovery.discover(repoPath:)` to `WorktreeDiscovery.discover(repo:)`:

- `Graftty/GrafttyApp.swift` — `reconcileOnLaunch` (~line 1488)
- `Graftty/GrafttyApp.swift` — FSEvents reconcile (~line 2980)
- `Graftty/GrafttyApp.swift` — relocate cascade (~line 3141)

`MainWindow.swift:addRepoFromPath` keeps the path-based call: it's only invoked on the git-tracked add branch, and it doesn't have a `RepoEntry` yet at that point. `AddWorktreeFlow.swift` is git-only by construction (it's the "create a new worktree" flow) and is never reached for a non-git repo.

### 4. Gating per-repo git operations

Three polling/refresh fan-outs run per-repo today. Each gets a one-line skip for non-git:

- **`RemoteBranchStore.refresh(repoPath:)`** — extended to also accept the flag (or filter at the call site). Non-git → return immediately, no `git ls-remote`.
- **`PRStatusStore`** — the internal loop over the `getRepos` snapshot filters to `repo.isGitTracked`. Non-git repos never enter the poll set.
- **`StatsStore`** (git-status badges) — same pattern: filter at per-repo dispatch.

The only per-worktree git operation in scope, `GitWorktreeRemove.remove`, is unreachable for a non-git repo because the menu hides Delete Worktree. Defense-in-depth: `performDeleteWorktree` asserts `repo.isGitTracked` and aborts otherwise, matching GIT-4.11's alert style.

FSEvents watchers run unchanged — they watch the folder, not `.git`. A non-git folder being deleted/moved still produces the same `.stale`/relocate signals; the cascade goes through `WorktreeDiscovery` and gets the synthetic worktree back.

### 5. Context menus + sidebar rendering

**Repo-row context menu (non-git):**

- Hide: "Add Worktree…".
- Show new item: **"Initialize Git Repository"** — calls `GitInit`, flips `repo.isGitTracked = true`, and triggers a reconcile so the synthetic worktree is replaced by the real `git worktree list --porcelain` result. Failures surface via the same alert.
- Keep: "Remove Repository" (removes the entry from Graftty; no `git worktree remove`).
- Keep: collapse, drag-reorder.

**Worktree-row context menu (non-git):**

- Hide: "Delete Worktree" (the worktree *is* the project; "Remove Repository" is the right action).
- Hide: PR-merged delete-offer affordances.
- Keep: pane operations, attention, focus, drag-reorder of panes within the worktree.

**Row visuals:** unchanged. The branch label reads `main`. The state icon follows pane activity. Display name comes from `URL(...).lastPathComponent`, same as today.

**Collapse arrow:** unchanged. A non-git repo always has exactly one worktree — same render rule.

### 6. Persistence and migration

- `state.json` gains one optional key, `isGitTracked`, on each repo entry.
- Decoding old blobs: `decodeIfPresent ?? true`. No migration step, no schema version bump.
- Encoding: always emits the key going forward.
- CLI surface (`graftty pane …`, `graftty team …`, `graftty notify`) unaffected. They look up worktrees by path; the synthetic worktree's path is the project folder. `WorktreeNameLookup` matches on basename and is git-agnostic.
- Per-worktree state under `<worktree>/.graftty/…` lands at `<project>/.graftty/…` for non-git repos — same code, same path rules.
- Bookmark-based rename recovery (LAYOUT-4.5..4.9) works unchanged: it's keyed on the repo folder, not the `.git` dir.
- `reconcileOnLaunch` loops `appState.repos` and calls `WorktreeDiscovery.discover(repo:)`. Non-git repos return their synthetic worktree; `WorktreeReconciler.reconcile` matches against persisted state the same way it does for git worktrees.

### 7. EARS specs

**Add-path extensions (`GIT-1`):**

- **GIT-1.5**: When the user selects via Add Repository a folder containing no `.git` entry up to the filesystem root, the application shall present a three-button choice — Initialize Git Repository, Add Without Git, Cancel — instead of the prior "Not a Git Repository" warning.
- **GIT-1.6**: When the user chooses Initialize Git Repository at add-time, the application shall run `git init` followed by `git commit --allow-empty -m "Initial commit"` in the folder, then proceed through the standard Add Repository flow.
- **GIT-1.7**: When the user chooses Add Without Git, the application shall register a repository entry whose `isGitTracked` is false and whose worktree list contains exactly one entry with `path` equal to the folder path and `branch` equal to `"main"`.

**Project-kind family (new prefix):**

- **PROJECT-1.0** (type-level `@spec` on `RepoEntry`): Each repository entry shall record whether its on-disk path is tracked by git.
- **PROJECT-1.1**: While a repository is not git-tracked, the application shall hide Add Worktree, Delete Worktree, and the PR-merged delete-offer affordance from its context menus.
- **PROJECT-1.2**: While a repository is not git-tracked, the application shall skip PR-status, remote-branch, and git-status polling for it.
- **PROJECT-1.3**: When the user selects Initialize Git Repository on a non-git repo's row, the application shall run `git init` + `git commit --allow-empty`, set `isGitTracked` to true, and rediscover its worktrees via `git worktree list --porcelain`.
- **PROJECT-1.4**: When `WorktreeDiscovery.discover` is invoked with a non-git-tracked repository, the application shall return exactly one synthesized `DiscoveredWorktree` with path equal to the repo path and branch `"main"`, without invoking git.
- **PROJECT-1.5**: When decoding a repository entry that lacks the `isGitTracked` key, the application shall default it to true so pre-feature `state.json` blobs load unchanged.

### 8. Tests

**Pure-Swift unit tests** (no subprocess; `Tests/GrafttyTests/Specs/ProjectTests.swift`, plus extensions to `GitTests.swift`):

- `@spec PROJECT-1.4`: `WorktreeDiscovery.discover` on `RepoEntry(isGitTracked: false, path: "/tmp/x")` returns `[DiscoveredWorktree(path: "/tmp/x", branch: "main")]` and does not invoke `GitRunner` (recording fake, assert call count 0).
- `@spec PROJECT-1.5`: Decoding a `RepoEntry` JSON blob that omits `isGitTracked` yields `isGitTracked == true`. Encoding a non-git entry then decoding round-trips to `false`.
- `@spec GIT-1.7`: Building a non-git `RepoEntry` produces exactly one `WorktreeEntry` with `path == repo.path` and `branch == "main"`.
- `@spec PROJECT-1.1` / `PROJECT-1.2`: small predicate tests on whatever gating helper we introduce, exercised by passing fixture `RepoEntry` values.

**Integration tests** (use a temp directory, real `git`; `Tests/GrafttyTests/Specs/GitInitTests.swift`):

- `@spec GIT-1.6`: `GitInit.run(at: tmpDir)` produces a `.git` directory and one commit (`git log --oneline` returns one line). Skip when `git` isn't on `PATH`.
- `@spec PROJECT-1.3`: Promote flow integration — start from a non-git `RepoEntry`, invoke the promote helper, assert (a) `.git` exists, (b) `isGitTracked == true`, (c) a fresh `WorktreeDiscovery.discover` returns the real porcelain output.

**UI-adjacent tests:**

- `@spec GIT-1.5`: Test the alert-construction helper that returns the three button titles and default. Matches the existing `ForceDeleteAlert.informativeText` pattern (no `NSAlert` in tests).

**Backlog inventory:** `Tests/GrafttyTests/Specs/ProjectTodo.swift` (new) and additions to `GitTodo.swift`, each entry as `@Test(.disabled("not yet implemented"))` until promoted.

**Regression coverage:** add a non-git `RepoEntry` to fixtures for drag-reorder, pane-control CLI, and team-membership specs to confirm the reuse claim. No new test files; reuse existing ones.

## Open questions

None at design time.

## Files touched (estimate)

- `Sources/GrafttyKit/Model/RepoEntry.swift` — add `isGitTracked`, decoder, type-level `@spec PROJECT-1.0`.
- `Sources/GrafttyKit/Git/WorktreeDiscovery.swift` — new facade.
- `Sources/GrafttyKit/Git/GitInit.swift` — new helper.
- `Sources/Graftty/Views/MainWindow.swift` — three-button alert, non-git add branch, promote action wiring, defense-in-depth on `performDeleteWorktree`.
- `Sources/Graftty/Views/SidebarView.swift` — context-menu conditional rendering.
- `Sources/Graftty/GrafttyApp.swift` — migrate three `discover` call sites to the facade.
- `Sources/GrafttyKit/PRStatus/PRStatusStore.swift` — filter on `isGitTracked`.
- `Sources/GrafttyKit/RemoteBranches/RemoteBranchStore.swift` (or equivalent) — short-circuit.
- `Sources/GrafttyKit/Stats/StatsStore.swift` (or equivalent) — short-circuit.
- `Tests/GrafttyTests/Specs/ProjectTests.swift` — new.
- `Tests/GrafttyTests/Specs/ProjectTodo.swift` — new (any specs not implemented in first pass).
- `Tests/GrafttyTests/Specs/GitInitTests.swift` — new.
- `Tests/GrafttyTests/Specs/GitTests.swift` — additions for `GIT-1.5..1.7`.
- `SPECS.md` — regenerated via `scripts/generate-specs.py`.
