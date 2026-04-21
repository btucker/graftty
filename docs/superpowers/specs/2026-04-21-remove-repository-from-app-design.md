# Remove Repository from App — Design

## Problem

Espalier has "Add Repository" (LAYOUT-3.1) and drag-drop repo add (LAYOUT-3.2) but no way to remove a repository from the sidebar. A user who added a repo they no longer want must hand-edit `state.json` to recover. `AppState.removeRepo(atPath:)` exists on the model but no UI invokes it.

This design adds a right-click context menu on repository rows with a "Remove Repository" action. The action is app-level only: no `git` is invoked, no files on disk are touched.

## UX

Right-clicking the repo header row (the `DisclosureGroup` label in `SidebarView.repoSection`) surfaces a context menu with one item: **Remove Repository**.

Clicking it presents an `NSAlert`:

- Message: `Remove "<repo displayName>"?`
- Informative: `This removes the repository from Espalier but does not delete any files from disk.`
- Buttons: **Remove**, **Cancel**.

On confirmation, the repository and all its worktrees disappear from the sidebar together. Stale state, running panes, focused-pane memory, collapse state, and offer-for-merged-PR markers all go with the repo. Files on disk — worktree directories, branches, git metadata — are untouched.

## Data flow

`SidebarView` gains a new closure `onRemoveRepo: (RepoEntry) -> Void`, passed from `MainWindow`. The `repoSection` view wraps its `DisclosureGroup` label in a `.contextMenu { ... }` with a single "Remove Repository" button that calls `onRemoveRepo(repo)`.

`MainWindow` adds two methods:

- `removeRepoWithConfirmation(_ repo: RepoEntry)` — runs the `NSAlert`, bails on Cancel, otherwise calls `performRemoveRepo`.
- `performRemoveRepo(_ repo: RepoEntry)` — performs the cascade below.

## Cascade (`performRemoveRepo`)

1. For every worktree in `repo.worktrees` whose `state == .running`, call `terminalManager.destroySurfaces(terminalIDs: wt.splitTree.allLeaves)`. This covers stale-while-running surfaces kept alive by GIT-3.4 — the `.running` gate is on the entry's state field, which is `.running` in both fresh-running and stale-while-running cases.
2. Call `services.worktreeMonitor.stopWatching(repoPath: repo.path)` — tears down the `.git/worktrees/` watcher and origin-refs watcher.
3. For each worktree in `repo.worktrees`, call `services.worktreeMonitor.stopWatchingWorktree(wt.path)` — tears down the path, HEAD-reflog, and content watchers (the fd-leak class GIT-3.11 protects against).
4. For each worktree in `repo.worktrees`, call `prStatusStore.clear(worktreePath: wt.path)` and `statsStore.clear(worktreePath: wt.path)`. Ordering before model removal matches GIT-3.6 / GIT-4.10 / GIT-3.13: orphan cache entries otherwise survive indefinitely keyed by a path nothing iterates.
5. Call `appState.removeRepo(atPath: repo.path)`. Persistence to `state.json` is driven by the existing `onChange(of: appState)` save trigger — no explicit save is needed.

## `AppState.removeRepo(atPath:)` correction

Currently `AppState.removeRepo(atPath:)` only mutates `repos`. If the caller removes a repo that contains the currently-selected worktree, `selectedWorktreePath` is left pointing at a worktree that no longer exists — a broken invariant that the symmetric helper `removeWorktree(atPath:)` already avoids (AppState.swift:82-91).

Teach `removeRepo(atPath:)` to clear `selectedWorktreePath` when that path belongs to any worktree in the repo being removed. Compute the set of victim paths before the `removeAll`, then clear selection if it's a member. This keeps the invariant at the model layer rather than re-asserting it at every call site — matching the established pattern.

## Ordering rationale

- **Surface teardown before model removal.** Same reason as GIT-3.10's Dismiss-while-running fix: leaving libghostty render/io/kqueue threads running after the model entry disappears has been observed to corrupt `os_unfair_lock` and SIGKILL the app.
- **Watcher teardown before model removal.** GIT-3.11 tracks fd-leak from DispatchSource cancel-handler lifetime. Leaving watchers live after the repo is gone from the model means the next `.git/worktrees/` FSEvents tick fires a reconcile against a path the model no longer knows — at best wasted work, at worst a phantom re-add.
- **Cache clear before model removal.** GIT-3.6, GIT-4.10, GIT-3.13 already enforce this for every other path-removal surface. A re-add of the same path later would otherwise inherit stale PR badges and stats.

## Error handling

None required. The cascade is pure in-memory work against app state, plus watcher / surface teardown whose underlying primitives are already idempotent. There is no subprocess, no filesystem mutation, no network call. If the user somehow fires the menu action twice (e.g. via a fast double-click), the second `performRemoveRepo` finds `repo.path` not in `appState.repos` and `appState.removeRepo(atPath:)`'s `removeAll` is a no-op; `stopWatching` on an already-stopped path is a no-op; `clear` on an already-cleared path is a no-op.

## Spec entries

New subsection **1.4 Removing Repositories** inserted after **1.3 Adding Repositories** in `SPECS.md`:

- **LAYOUT-4.1** When the user right-clicks a repository header row in the sidebar, the application shall display a context menu containing a "Remove Repository" action.
- **LAYOUT-4.2** When the user triggers "Remove Repository", the application shall display a confirmation dialog whose informative text explicitly states "This removes the repository from Espalier but does not delete any files from disk."
- **LAYOUT-4.3** When the user confirms "Remove Repository", the application shall (a) tear down all terminal surfaces in every worktree of the repository whose `state == .running`, (b) stop the repository-level FSEvents watchers (`.git/worktrees/` and origin refs) and each worktree's per-path, HEAD-reflog, and content watchers, (c) clear the cached PR status and divergence stats for every worktree of the repository, (d) clear `selectedWorktreePath` if it pointed to any worktree in the repository, and (e) remove the repository entry from `AppState`. Steps (a)–(d) must precede (e) for the same orphan-surfaces / orphan-caches reasons as GIT-3.10 / GIT-4.10 / GIT-3.13 and the watcher-fd-lifetime reason as GIT-3.11.
- **LAYOUT-4.4** The "Remove Repository" action shall not invoke `git` and shall not modify any files on disk. Worktree directories, branches, and git metadata remain untouched; the operation affects only Espalier's in-memory model and persisted `state.json`.

## Tests

`Tests/EspalierKitTests/Model/AppStateTests.swift`:

- `removeRepo_clearsSelection_whenSelectedWorktreeIsInsideRemovedRepo` — selection was inside the removed repo; after `removeRepo`, `selectedWorktreePath == nil`.
- `removeRepo_preservesSelection_whenSelectedWorktreeIsInDifferentRepo` — selection is in a repo that survives; `selectedWorktreePath` is unchanged.
- `removeRepo_unknownPath_isNoOp` — no matching repo; `repos` and `selectedWorktreePath` unchanged.
- `removeRepo_selectionIsRepoMainCheckoutPath_clearsSelection` — the main-checkout worktree path equals the repo's `path`; selection clear still fires.

Higher-level `performRemoveRepo` behavior (surface teardown, watcher stop, cache clear) is exercised either via an existing test harness analogous to the `performDeleteWorktree` pattern, or via targeted unit tests against the injectable collaborators (`TerminalManager`, `WorktreeMonitor`, `PRStatusStore`, `WorktreeStatsStore`) if such a harness is not yet available. The implementation plan will pick between those based on current test infrastructure.

## Files touched

- `Sources/EspalierKit/Model/AppState.swift` — teach `removeRepo(atPath:)` to clear `selectedWorktreePath` when it belongs to the removed repo.
- `Sources/Espalier/Views/SidebarView.swift` — add `onRemoveRepo: (RepoEntry) -> Void`; attach a `.contextMenu` with "Remove Repository" to the repo header row.
- `Sources/Espalier/Views/MainWindow.swift` — add `removeRepoWithConfirmation(_:)` and `performRemoveRepo(_:)`; wire `onRemoveRepo: removeRepoWithConfirmation` into `SidebarView`.
- `Tests/EspalierKitTests/Model/AppStateTests.swift` — new cases listed above.
- `SPECS.md` — new §1.4 with LAYOUT-4.1 … LAYOUT-4.4.

## Non-goals

- No deletion of any filesystem content. `git worktree remove`, `rm -rf`, and branch manipulation are all out of scope.
- No undo. The next Add Repository re-discovers the same worktrees from disk; sub-second in-app state (focused pane per worktree, split-tree layouts, collapse state, offered-PR markers) is accepted as lost on remove.
- No keyboard shortcut. Right-click discovery is sufficient for a low-frequency action; a shortcut can be layered later without schema changes.
- No bulk remove. Single-repo scope matches every other item in the existing sidebar context menus.
