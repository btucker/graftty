# Stable Main-Checkout Sidebar Label

**Date:** 2026-05-15
**Status:** Draft (design approved, awaiting plan)

## Problem

The sidebar row for a repo's main checkout currently labels itself by the worktree's current git branch (`SidebarWorktreeLabel.swift:33` returns `worktree.displayBranch` when `worktree.path == repoPath`). This was a deliberate choice — the directory basename equals the repo name shown one row up, so the branch name carried the only useful information.

The side effect is that any `git checkout` inside the main worktree renames the row. After checking out `feature-x`, there is no row labelled with the repo's default branch (e.g. `main`), so the user has no stable click target to navigate "home." Checking back out to the default branch *should* restore the label but in practice does not always do so promptly (a separate reconciler bug — out of scope here, tracked separately).

Feature-worktree rows do not have this problem: their labels come from the directory path, which is invariant under `git checkout`.

## Goal

The main-checkout row should represent the repository's **home base** — a stable identity that survives local branch switches — while still surfacing the current HEAD when it diverges, so the user is never confused about what's actually checked out.

The repo's default branch name must be resolved at runtime (no hardcoded `"main"` — users have arbitrary default branch names).

## Design

### Behavior

**Main-checkout row labeling.**

- Primary label: the repository's **default branch name**, resolved per the chain below. Stable across local `git checkout`.
- Secondary label: the current HEAD branch, rendered in the existing dimmed `.caption` style at `WorktreeRow.swift:361`. Appears iff current branch ≠ default branch. Same visual treatment as feature-worktree rows use today when their directory name diverges from their branch.
- Italic styling on the primary label is preserved.

**Main-checkout row icon.**

- Always `house`. `WorktreeRowIcon.symbolName` short-circuits on `isMainCheckout` before the existing PR-flip. The `#NNN` PR badge text on the row continues to convey PR state.

**Default-branch resolution chain** (first that succeeds wins):

1. `git symbolic-ref --short refs/remotes/origin/HEAD` (stripped of the `origin/` prefix), polled by `RemoteBranchStore` alongside the existing remote-branch listing.
2. `RepoEntry.defaultBranchHint` — the branch observed at the moment the repo was first added to Graftty, persisted on the repo entry.
3. Hardcoded `"main"` so the UI never goes blank.

Considered and dropped: `git config init.defaultBranch` as an intermediate step. `defaultBranchHint` captures the same intent (whatever the user's git config produced at the moment of repo creation) without an extra subprocess or a session-scoped cache.

### Non-goals

- Feature-worktree row behavior is unchanged.
- The breadcrumb and PR badge in the content area continue to follow the current HEAD (today's behavior).
- Auto-reparenting panes between worktrees on shell `cd` is out of scope (and not part of this design's mechanism).
- The "switch back to default branch doesn't relabel promptly" reconciler bug is fixed separately (the new design reduces user impact because the primary label is now stable, but the dimmed secondary caption still depends on the reconciler).

### Data model

`RemoteBranchSnapshot` gains:

```swift
public let defaultBranch: String?
```

`nil` when `origin/HEAD` is unset or the lookup fails.

`RemoteBranchStore.defaultList` adds a third concurrent `async let` call:

```swift
async let defaultBranchTask = GitRunner.run(
    args: ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
    at: repoPath
)
```

Parsed to strip the leading `origin/`. On error, `nil`. Same polling cadence, FSEvents arming, and pulse semantics as the existing remote-branch fields.

`RepoEntry` gains:

```swift
public var defaultBranchHint: String?
```

Written once by `MainWindow.addRepoFromPath` (line 835) when the `RepoEntry(...)` is constructed at line 869 — snapshot the main-checkout worktree's branch at that moment. Migration mirrors the existing pattern at `RepoEntry.swift:55` — `decodeIfPresent` defaults pre-feature blobs to `nil`. Existing repos rely on the `origin/HEAD` snapshot path to provide the label; the hint only ever covers the offline / no-remote case for newly added repos.

### Resolution call site

`SidebarWorktreeLabel.text` is extended:

```swift
public static func text(
    for worktree: WorktreeEntry,
    inRepoAtPath repoPath: String,
    siblingPaths: [String],
    defaultBranch: String?    // new: pre-resolved by caller
) -> String {
    if worktree.path == repoPath {
        return defaultBranch ?? "main"
    }
    return worktree.displayName(amongSiblingPaths: siblingPaths)
}
```

The caller (`SidebarView.repoSection`, `MainWindow.worktreeDisplayName`, `PaneMoveMenuBuilder`) resolves the chain:

```swift
let defaultBranch =
    remoteBranchStore.branchesByRepo[repo.path]?.defaultBranch
    ?? repo.defaultBranchHint
```

Falls through to `"main"` inside `SidebarWorktreeLabel.text` when both are nil.

### Secondary caption — no view code change

`WorktreeRow.branchLabel` already renders:

```swift
if entry.displayBranch != displayName {
    Text(entry.displayBranch)
        .font(.caption)
        .foregroundColor(theme.foreground.opacity(0.45))
}
```

Once `displayName` for the main checkout equals the default branch (passed from `SidebarWorktreeLabel.text`), this dedup condition automatically renders the current-HEAD caption iff the current branch differs from the default. No new conditional, no new view.

### Icon change

`WorktreeRowIcon.symbolName` reorders:

```swift
public static func symbolName(isMainCheckout: Bool, hasPR: Bool) -> String {
    if isMainCheckout { return "house" }
    if hasPR { return "arrow.triangle.pull" }
    return "arrow.triangle.branch"
}
```

## Touchpoints

- `Sources/GrafttyKit/Git/RemoteBranchStore.swift` — extend `RemoteBranchSnapshot`, extend `defaultList`, parse output.
- `Sources/GrafttyKit/Model/RepoEntry.swift` — add `defaultBranchHint`, extend `CodingKeys`, extend custom `init(from:)` with `decodeIfPresent`.
- `Sources/Graftty/Views/MainWindow.swift` (`addRepoFromPath`, line 835; `RepoEntry(...)` construction line 869) — populate `defaultBranchHint` from the discovered main-checkout worktree's branch.
- `Sources/GrafttyKit/Model/SidebarWorktreeLabel.swift` — extend signature, swap the main-checkout return path.
- `Sources/Graftty/Views/SidebarView.swift` — thread `defaultBranch` through `repoSection` → `worktreeBlock`.
- `Sources/Graftty/Views/MainWindow.swift` — same threading at `worktreeDisplayName` (line 256) and the move-menu path (line 777).
- `Sources/Graftty/Terminal/PaneMoveMenuBuilder.swift` — same threading.
- `Sources/GrafttyProtocol/WorktreeRowIcon.swift` — reorder conditions.

## Specs (EARS)

New requirements (`LAYOUT-` prefix, exact IDs assigned at promotion from `LayoutTodo.swift`):

- The application shall display the repository's default branch name as the main-checkout row's primary label, regardless of the worktree's current HEAD.
- When the main-checkout worktree's current branch differs from the repository's default branch, the application shall display the current branch as a dimmed secondary caption on the row.
- The main-checkout row's leading icon shall always be `house`, regardless of associated PR state.
- The application shall resolve a repository's default branch via the chain: `origin/HEAD` from the remote-branch snapshot → `RepoEntry.defaultBranchHint` → `"main"`.
- `RemoteBranchSnapshot` shall include the repository's default branch as resolved from `git symbolic-ref --short refs/remotes/origin/HEAD`, or `nil` when the lookup fails.

## Testing

Per the project TDD process — disabled `LayoutTodo.swift` entries promoted to failing tests, then implementation:

- `RemoteBranchStore` parser fixture: stdout `"origin/main\n"` yields `defaultBranch == "main"`; empty stdout / non-zero exit yields `nil`.
- `SidebarWorktreeLabel.text` resolution: main-checkout returns the passed `defaultBranch`; falls back to `"main"` when nil.
- `WorktreeRowIcon.symbolName`: `isMainCheckout=true, hasPR=true` returns `"house"`; `isMainCheckout=false, hasPR=true` returns `"arrow.triangle.pull"`.
- `RepoEntry` decoding: pre-feature JSON blob (no `defaultBranchHint` key) decodes successfully with `defaultBranchHint == nil`.
- Integration-style: feed a snapshot with `defaultBranch = "trunk"` and a worktree on branch `feature-x`, assert the row's primary label is `"trunk"` and the secondary caption renders `"feature-x"`.

## Migration

- Existing `state.json` blobs lack `defaultBranchHint`; `decodeIfPresent` defaults to `nil`. UI degrades to fallback chain step 3 (`"main"`) until the next `RemoteBranchStore` poll resolves `origin/HEAD`. For repos with no `origin` remote, the user sees `"main"` until they next add a remote and Graftty resolves `origin/HEAD` — acceptable because `defaultBranchHint` is only ever populated for *newly added* repos under this design.
- No state file version bump required.
