# Repository Lifecycle — Remove, Rename, and Move Recovery — Design

## Problem

Graftty has Add Repository (LAYOUT-3.x) but no complementary remove action, and it tracks repositories by absolute path — so a Finder-side rename or move of the repo folder silently turns every worktree stale despite the folder still existing.

Two related gaps, one design:

1. **No remove.** `AppState.removeRepo(atPath:)` exists on the model but no UI invokes it. A user who added a repo they no longer want must hand-edit `state.json` to recover.
2. **Brittle path tracking.** `RepoEntry.path` is stored as an absolute path string. When the user renames the repo folder, or any ancestor of it, FSEvents reports the old path missing and every worktree inside transitions to `.stale` — even though the folder still exists at its new location.

This design adds a right-click "Remove Repository" context-menu action and introduces `URL` bookmark-backed repository tracking so renames and moves recover transparently.

## UX

### Remove Repository

Right-clicking the repo header row (the `DisclosureGroup` label in `SidebarView.repoSection`) surfaces a context menu with **Remove Repository**. Clicking it presents an `NSAlert`:

- Message: `Remove "<repo displayName>"?`
- Informative: `This removes the repository from Graftty but does not delete any files from disk.`
- Buttons: **Remove**, **Cancel**.

On confirmation, the repository and all its worktrees disappear from the sidebar together. Files on disk — worktree directories, branches, git metadata — are untouched.

### Rename / Move recovery

There is no user-visible UI for rename recovery. The sidebar labels simply update to reflect the new folder name. Recovery runs automatically:

- At launch, before FSEvents watchers are installed.
- When an FSEvents deletion event fires on a watched repo path, before the worktree is transitioned to `.stale`.

If recovery succeeds, the user sees nothing except the updated label. If it fails (bookmark resolution returns an error, the resolved location is no longer a git repository, or `git worktree repair` fails), the repo's worktrees fall through to the existing `.stale` behavior.

## Schema

### `RepoEntry.bookmark: Data?`

`RepoEntry` gains an optional field:

```swift
public var bookmark: Data?
```

Holds the bytes returned by `URL(fileURLWithPath: path).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)` at repo-add time. Regular (not security-scoped) bookmarks are sufficient because Graftty is not sandboxed — `NSOpenPanel` already hands us arbitrary-path URLs. Security-scoped bookmarks would require pairing every resolve with `startAccessingSecurityScopedResource()` / `stopAccessing…`, adding complexity with no access gained.

### Codable migration

`RepoEntry` becomes `Codable` via an explicit `init(from:)` using `decodeIfPresent` for `bookmark`, matching the existing pattern in `WorktreeEntry.init(from:)` (see WorktreeEntry.swift:57 onward). A pre-migration `state.json` decodes cleanly with `bookmark == nil`; on first launch after upgrade, such repos are treated as "needs bookmark" — see below.

### No per-worktree bookmarks

Worktree paths are recovered derivatively: once the repo relocates, we re-run `git worktree list --porcelain` from the new repo path, and that is the authoritative source of current linked-worktree paths. Individual-worktree Finder-moves (without `git worktree move`) are out of scope — `git worktree move` is the supported way to move a linked worktree, and such a move updates git's bookkeeping automatically.

## Data flow — Remove Repository

`SidebarView` gains `onRemoveRepo: (RepoEntry) -> Void`. The `repoSection` view wraps its `DisclosureGroup` label in `.contextMenu { Button("Remove Repository") { onRemoveRepo(repo) } }`.

`MainWindow` adds:

- `removeRepoWithConfirmation(_ repo: RepoEntry)` — runs the `NSAlert`; on Cancel returns; otherwise calls `performRemoveRepo`.
- `performRemoveRepo(_ repo: RepoEntry)` — cascade below.

### Remove cascade

1. For each worktree in `repo.worktrees` whose `state == .running`, call `terminalManager.destroySurfaces(terminalIDs: wt.splitTree.allLeaves)`. Covers stale-while-running surfaces (GIT-3.4).
2. `services.worktreeMonitor.stopWatching(repoPath: repo.path)` — tears down `.git/worktrees/` and origin-refs watchers.
3. For each worktree in `repo.worktrees`, `services.worktreeMonitor.stopWatchingWorktree(wt.path)` — tears down path, HEAD-reflog, content watchers (fd-leak class per GIT-3.11).
4. For each worktree, `prStatusStore.clear(worktreePath: wt.path)` and `statsStore.clear(worktreePath: wt.path)`. Ordering before model removal per GIT-3.6 / GIT-4.10 / GIT-3.13.
5. `appState.removeRepo(atPath: repo.path)`. Persistence to `state.json` is driven by the existing `onChange(of: appState)` save trigger.

The bookmark bytes are stored on the repo entry itself, so removal discards them naturally.

### `AppState.removeRepo(atPath:)` correction

`AppState.removeRepo(atPath:)` currently only mutates `repos` (AppState.swift:37). If the removed repo contained the currently-selected worktree, `selectedWorktreePath` is left pointing at a worktree that no longer exists — a broken invariant the symmetric `removeWorktree(atPath:)` already avoids (AppState.swift:82). Teach `removeRepo(atPath:)` to compute the victim path set before the `removeAll`, then clear `selectedWorktreePath` if it's a member.

## Data flow — Rename / Move recovery

### Minting bookmarks

At every point a `RepoEntry` is created — `MainWindow.addRepoFromPath` — the bookmark is minted:

```swift
let bookmark = try? URL(fileURLWithPath: repoPath).bookmarkData(
    options: [],
    includingResourceValuesForKeys: nil,
    relativeTo: nil
)
```

A nil return (e.g. the folder was unlinked in the millisecond between picking it and minting) does not block the add — the repo is created with `bookmark == nil`. The recovery path simply doesn't fire for such repos; the regression is to the pre-design status quo.

### Migration of pre-existing repos

On launch, for each repo in the loaded `AppState` where `bookmark == nil`:

- If `FileManager.default.fileExists(atPath: repo.path)` returns true, mint a fresh bookmark from the stored path and write it back to the `RepoEntry`. `onChange(of: appState)` persists it.
- If the path doesn't exist and no bookmark lets us find the new location, leave `bookmark == nil` and let the existing stale machinery handle the worktrees. A later re-add will mint.

### Launch-time resolution

Before `WorktreeMonitor` watchers are installed (currently near the top of `reconcileOnLaunch`), for each repo whose `bookmark != nil`:

1. Call `URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)`.
2. If resolution throws (file no longer exists anywhere discoverable), leave the repo alone; its worktrees will surface as `.stale` via the normal reconcile path.
3. If the resolved `URL.path` differs from `repo.path`, run **Relocate cascade** (below).
4. If `isStale == true` (cross-volume move or iCloud resolution), mint a fresh bookmark from the resolved URL and store it.

### Runtime recovery on deletion

In `worktreeMonitorDidDetectDeletion`, before the existing "transition to `.stale`" block:

1. Identify the owning `RepoEntry` for the deleted `worktreePath` via `appState.repo(forWorktreePath:)`.
2. If that repo's `bookmark != nil`, resolve it. If the resolved `URL.path` differs from `repo.path`, run **Relocate cascade**. After relocation the worktree path is likely no longer deleted — re-run discovery reconciliation.
3. If resolution fails, the resolved location is no longer a git repo, or the worktree is genuinely gone post-relocate, fall through to the existing `.stale` path.

Two entry points, one cascade.

### Relocate cascade

Given a `RepoEntry` at index `repoIdx` with a resolved `newURL` different from `repo.path`:

1. Verify `newURL.path/.git` exists (either as a file, for linked worktrees, or as a directory, for the main checkout). If not, abort relocation — the bookmark resolved to a folder that is no longer a git repo.
2. Stop all watchers tied to old paths: `worktreeMonitor.stopWatching(repoPath: repo.path)` plus `stopWatchingWorktree(wt.path)` for each worktree.
3. Run `GitWorktreeDiscovery.discover(repoPath: newURL.path)`. If this throws, swallow and abort relocation; worktrees fall through to the existing `.stale` path. The add-repository NSAlert path (GIT-1.2) does not apply — relocation is background work the user did not directly trigger, so an alert mid-launch or mid-FSEvents-tick would be surprising noise.
4. If the discovery result omits any linked worktree we had before — suggesting git's internal pointers are broken by the move — run `git worktree repair` from `newURL.path`. Then re-run `discover`. If it still omits, those worktrees are genuinely lost; they'll be dropped from the model as they would be in any reconcile cycle.
5. Compute the new model: `appState.repos[repoIdx].path = newURL.path`; update `displayName` to `newURL.lastPathComponent`; for each discovered worktree, match to an existing `WorktreeEntry` by **branch name** (stable across path changes) and preserve `id`, `splitTree`, `state`, `focusedTerminalID`, `paneAttention`, `attention`, `offeredDeleteForMergedPR`. Update its `path` to the discovered path. Discovered worktrees with no branch match are appended as fresh entries; unmatched existing entries are dropped (git no longer lists them).
6. Clear `prStatusStore` and `statsStore` for every old worktree path whose path changed. Their caches are path-keyed — leaving them by the old path would both leak and render wrong on a future same-path re-add.
7. If `appState.selectedWorktreePath` matched any old worktree path, update it to the corresponding new path (preserving selection across the rename).
8. Re-install watchers at the new paths: `worktreeMonitor.watchWorktreeDirectory(repoPath: newURL.path)`, `watchOriginRefs(repoPath: newURL.path)`, and per-worktree `watchWorktreePath` / `watchHeadRef` / `watchWorktreeContents`.
9. `onChange(of: appState)` persists the updated `path`, `displayName`, and (if re-minted) `bookmark`.

Ordering rationale:
- Watchers stopped before discovery so a discovery-triggered rescan event doesn't fire against a zombie watcher.
- Discovery before model mutation so an unrecoverable throw leaves the model unchanged and we can fall through to `.stale`.
- Cache clear tied to the per-path change, not repo-wide, because in most moves only the path *prefix* changes and clearing caches that would still be valid on the same-branch worktree (just at a new path) is wasteful — but we accept this cost to keep the rule simple and avoid a key-rewrite API surface on the stores.

## Edge cases

- **Cross-volume move (`isStale == true`).** Mint a fresh bookmark from the resolved URL and store it. Subsequent resolutions will not be stale.
- **Repo copied between machines via `state.json` sync.** Bookmarks are machine-local. On the new machine, `URL(resolvingBookmarkData:)` fails. The code falls back to `repo.path` as-is; if the path resolves on this machine, the existing flow works; if not, stale. On the next successful access (first subsequent add-or-launch-with-path-existing), a fresh bookmark is minted.
- **Two repos at paths that share a prefix, one renamed.** Bookmarks track the specific folder (inode + volume), not the path string — the other repo is unaffected.
- **User renames the repo folder while Graftty is open.** FSEvents on the worktree-path watchers fire deletion. `worktreeMonitorDidDetectDeletion` runs bookmark resolution first, relocate cascade fires, watchers re-install at the new paths, user sees the sidebar label update.
- **User renames a parent directory.** Same mechanism — bookmarks resolve to the new location regardless of whether the rename happened at the tracked folder itself or any ancestor.
- **User deletes the folder entirely.** Bookmark resolution throws. Fall through to existing stale behavior (GIT-3.3).
- **User renames, then re-creates a different folder at the old path.** Bookmark resolves to the actual original folder at its new location. The new folder at the old path is a different inode — the bookmark doesn't mis-fire. A user who wanted to "swap repos" at the same path needs to Add Repository explicitly.
- **User adds the same folder twice (via Finder-rename round-trip).** After a rename and back, the bookmark of the original entry resolves to the current path, which may or may not equal its stored path — either way the relocate cascade is idempotent when `newURL.path == repo.path`.

## Error handling

- Bookmark minting: failures are non-fatal (field is optional). A repo without a bookmark cannot auto-recover; it behaves exactly like pre-migration Graftty.
- Bookmark resolution: throws are caught silently; the existing `.stale` path handles the visible behavior.
- `git worktree repair` runs only when discovery comes back short and would otherwise drop worktrees. A failed `repair` leaves the missing worktrees dropped — no worse than dropping them without repair.
- `GitWorktreeDiscovery.discover` throws: during relocation, swallow and fall through to `.stale`. The add-repository NSAlert path (GIT-1.2) does not apply here because relocation is background work the user did not directly trigger.

## Spec entries

New subsection **1.4 Repository Lifecycle** inserted after **1.3 Adding Repositories** in `SPECS.md`, containing both groups.

### Remove

- **LAYOUT-4.1** When the user right-clicks a repository header row in the sidebar, the application shall display a context menu containing a "Remove Repository" action.
- **LAYOUT-4.2** When the user triggers "Remove Repository", the application shall display a confirmation dialog whose informative text explicitly states "This removes the repository from Graftty but does not delete any files from disk."
- **LAYOUT-4.3** When the user confirms "Remove Repository", the application shall (a) tear down all terminal surfaces in every worktree of the repository whose `state == .running`, (b) stop the repository-level FSEvents watchers (`.git/worktrees/` and origin refs) and each worktree's per-path, HEAD-reflog, and content watchers, (c) clear the cached PR status and divergence stats for every worktree of the repository, (d) clear `selectedWorktreePath` if it pointed to any worktree in the repository, and (e) remove the repository entry from `AppState`. Steps (a)–(d) must precede (e) for the same orphan-surfaces / orphan-caches reasons as GIT-3.10 / GIT-4.10 / GIT-3.13 and the watcher-fd-lifetime reason as GIT-3.11.
- **LAYOUT-4.4** The "Remove Repository" action shall not invoke `git` and shall not modify any files on disk. Worktree directories, branches, and git metadata remain untouched; the operation affects only Graftty's in-memory model and persisted `state.json`.

### Rename / Move recovery

- **LAYOUT-4.5** When the user adds a repository, the application shall record a `URL` bookmark (`URL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)`) for the repository folder and persist it on the `RepoEntry` alongside the path. Bookmark minting failures shall be non-fatal — the repository entry shall be created with a nil bookmark and forgo auto-recovery.
- **LAYOUT-4.6** On launch, before FSEvents watchers are installed, for each repository entry whose bookmark is non-nil, the application shall resolve the bookmark via `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)`. If the resolved path differs from the stored `RepoEntry.path`, the application shall run the relocate cascade described in LAYOUT-4.8. If the bookmark is resolvable but stale (cross-volume move), the application shall re-mint and persist a fresh bookmark from the resolved URL.
- **LAYOUT-4.7** When `WorktreeMonitor` reports a deletion event for a worktree path whose owning repository has a non-nil bookmark, the application shall resolve the bookmark and, if the resolved path differs from the stored `RepoEntry.path`, run the relocate cascade described in LAYOUT-4.8 before applying the existing transition-to-`.stale` path (GIT-3.3). If bookmark resolution fails or the resolved folder is no longer a git repository, the application shall fall through to the existing `.stale` path.
- **LAYOUT-4.8** The relocate cascade for a repository resolved to `newURL` differing from the stored path shall: (a) verify a `.git` entry exists at `newURL.path`, aborting if not, (b) stop all existing watchers tied to old paths, (c) run `GitWorktreeDiscovery.discover(repoPath: newURL.path)`, running `git worktree repair` and re-discovering if any previously-known linked worktree is omitted from the discovery result, (d) update the `RepoEntry`'s `path` and `displayName` to the new location, (e) match each existing `WorktreeEntry` to a discovered worktree by **branch name** and preserve `id`, `splitTree`, `state`, `focusedTerminalID`, `paneAttention`, `attention`, and `offeredDeleteForMergedPR`, updating only `path`, (f) clear per-path PR-status and divergence-stats cache entries for every worktree whose path changed, (g) update `selectedWorktreePath` from its old path to the corresponding new path if applicable, and (h) re-install repository-level and per-worktree FSEvents watchers at the new paths. Steps (a)–(c) shall precede (d) so that a discovery failure leaves the model unchanged.
- **LAYOUT-4.9** For a repository entry loaded from `state.json` without a bookmark (migration from a pre-LAYOUT-4.5 build), the application shall mint a fresh bookmark from the stored `path` if that path still resolves on disk, and persist it.
- **LAYOUT-4.10** The application shall use regular (not security-scoped) bookmarks. Security-scoped bookmarks are unnecessary because Graftty is not sandboxed and `NSOpenPanel` already grants the app arbitrary-path URLs.

## Tests

### `Tests/GrafttyKitTests/Model/AppStateTests.swift`

- `removeRepo_clearsSelection_whenSelectedWorktreeIsInsideRemovedRepo`.
- `removeRepo_preservesSelection_whenSelectedWorktreeIsInDifferentRepo`.
- `removeRepo_unknownPath_isNoOp`.
- `removeRepo_selectionIsRepoMainCheckoutPath_clearsSelection`.

### `Tests/GrafttyKitTests/Model/RepoEntryCodableTests.swift` (new)

- `roundTrip_preservesBookmark_whenPresent`.
- `decode_omittedBookmark_yieldsNilBookmark` — schema-migration path.

### `Tests/GrafttyKitTests/Git/BookmarkRelocateTests.swift` (new, uses `FileManager`-created temp repos)

Each test sets up a throwaway git repo in a temporary directory, mints a bookmark, renames the folder, and exercises the resolution path:

- `resolveBookmark_afterRename_returnsNewPath`.
- `resolveBookmark_afterParentRename_returnsNewPath`.
- `resolveBookmark_afterDelete_throws`.
- `resolveBookmark_acrossVolumes_reportsStaleAndResolves` — skipped on CI unless a second volume is mountable.
- `relocateCascade_preservesSplitTreeAndFocusOnRename` — seeds a `WorktreeEntry` with a non-trivial `splitTree` and `focusedTerminalID`, runs the cascade, asserts the new entry at the new path has the same id / splitTree / focus.
- `relocateCascade_matchesWorktreesByBranchNotPath` — ensures branch-based matching survives path changes.
- `relocateCascade_dropsWorktreesAbsentFromRediscovery`.
- `relocateCascade_abortsWhenResolvedFolderIsNotGitRepo` — delete `.git` in the resolved folder; cascade aborts; model unchanged.

Higher-level coverage of runtime recovery (FSEvents-deletion entry point) and launch-time recovery (`reconcileOnLaunch` entry point) is handled via existing-harness-style tests wired through the injectable collaborators. If the current `performDeleteWorktree` testing pattern doesn't already expose the relocate surface, the implementation plan will either extend that harness or add a narrower unit seam.

## Files touched

- `Sources/GrafttyKit/Model/AppState.swift` — teach `removeRepo(atPath:)` to clear `selectedWorktreePath`.
- `Sources/GrafttyKit/Model/RepoEntry.swift` — add `bookmark: Data?`, add custom `init(from:)` using `decodeIfPresent`.
- `Sources/GrafttyKit/Git/RepoBookmark.swift` (new) — small module wrapping mint / resolve so call sites stay readable and tests are easy.
- `Sources/GrafttyKit/Git/RepoRelocator.swift` (new) — owns the relocate cascade, depending on `GitWorktreeDiscovery`, `WorktreeMonitor`, `PRStatusStore`, `WorktreeStatsStore` via protocol seams.
- `Sources/Graftty/Views/SidebarView.swift` — add `onRemoveRepo`; attach `.contextMenu` to repo header row.
- `Sources/Graftty/Views/MainWindow.swift` — add `removeRepoWithConfirmation`, `performRemoveRepo`; add bookmark minting in `addRepoFromPath`; add launch-time resolve in `reconcileOnLaunch`; add runtime resolve in the delegate's `worktreeMonitorDidDetectDeletion` path before `.stale` transition.
- `Tests/GrafttyKitTests/Model/AppStateTests.swift` — new `removeRepo` cases.
- `Tests/GrafttyKitTests/Model/RepoEntryCodableTests.swift` (new).
- `Tests/GrafttyKitTests/Git/BookmarkRelocateTests.swift` (new).
- `SPECS.md` — new §1.4 with LAYOUT-4.1…4.10.

## Non-goals

- **No deletion of any filesystem content on Remove.** `git worktree remove`, `rm -rf`, branch manipulation all out of scope for the Remove path.
- **No undo for Remove.** The next Add Repository re-discovers the same worktrees from disk; transient in-app state (focused pane per worktree, split-tree layouts, collapse state, offered-PR markers) is accepted as lost.
- **No per-worktree bookmarks.** Individual-worktree Finder-moves (without `git worktree move`) are not auto-recovered. Such moves already require `git worktree repair`; they remain a user-side operation.
- **No cross-machine sync.** Bookmarks are machine-local filesystem references. If `state.json` is copied between machines, auto-recovery is unavailable on the new machine until a fresh bookmark is minted via a successful path-based resolution.
- **No user-visible rename-detected UI.** Recovery is transparent (choice A from brainstorm); the sidebar label change is the only signal. A prompt-on-detect flow was considered and rejected.
- **No bulk remove.** Single-repo scope matches every other item in the sidebar context menus.
- **No keyboard shortcut for Remove.** Right-click discovery is sufficient for a low-frequency action.
