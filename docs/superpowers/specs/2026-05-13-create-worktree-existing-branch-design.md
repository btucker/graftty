# Create worktree with an existing branch — design

## Goal

Let the user pick an existing branch when creating a worktree, instead of always creating a new one. Cover both branch sources (local refs and remote-only refs), annotate rows with enough metadata to distinguish branches at a glance (PR/MR number+title, last-commit date), dim branches already mounted in another worktree of the same repo, and block actions git would reject (mounting a branch that's already checked out in a sibling worktree).

## Scope

Three call sites that today share `AddWorktreeFlow`:

- **Mac** `Sources/Graftty/Views/AddWorktreeSheet.swift` (SwiftUI sheet).
- **iOS** `Sources/GrafttyMobileKit/UI/AddWorktreeSheetView.swift` (SwiftUI form sheet).
- **Web** `POST /worktrees` via `WebServerController` (HTTP).

Both branch sources are in scope: `refs/heads/` (local) and `refs/remotes/origin/*` (remote-only). For remote-only branches, the create flow lets git create a local tracking branch as a side effect of `git worktree add <path> origin/<name>`.

## UI

### Mac and iOS sheet

A segmented control (`SwiftUI.Picker` with `.segmented` style) labelled "New branch" / "Existing branch" appears above the branch input. Default is **New branch** so the common case (start a fresh branch) is one less click than today.

- **New branch** mode renders today's `TextField`. No behavioral change — `branchMirrorsWorktree` semantics preserved.
- **Existing branch** mode renders a `BranchComboBox` view (Mac) or pushes a `BranchPickerView` list (iOS). Same data model in both.

The picker shows one row per branch with this layout:

```
<branch-name>    <PR #N · title>          <relative date>
```

- Branches **mounted in another worktree of the same repo** are dimmed, strikethrough, and unselectable (`.disabled(true)` + `.opacity(0.5)`). A small italic annotation "in worktree <path-basename>" replaces the PR column for those rows.
- Rows are sorted by **last-commit date descending**.
- Typing in the input filters by substring match on branch name.
- On selection, the worktree-name field auto-fills with the branch name. A new `worktreeMirrorsBranch` flag (analog to today's `branchMirrorsWorktree`) starts `true` when the picker mode opens; the first manual edit of the worktree-name field flips it to `false` and subsequent branch selections leave the field alone.

### Web/HTTP

`POST /worktrees` request body gains:

```json
{ "repoPath": "...", "worktreeName": "...", "branchName": "...", "existing": true }
```

`existing` is optional, default `false` (back-compat with the current iOS and CLI clients). When `true`, the server takes the `useExisting` path. When `false`, behavior is identical to today.

## Data model

### `BranchPickerEntry`

```swift
public struct BranchPickerEntry: Sendable, Hashable {
    public enum Source { case local, remoteOnly }
    public struct PRSummary: Sendable, Hashable {
        public let number: Int
        public let title: String
    }
    public let name: String
    public let source: Source
    public let lastCommitDate: Date
    public let mountedWorktreePath: String?  // non-nil → dimmed
    public let pr: PRSummary?
}
```

### `BranchSelection` (replaces the current `branchName: String` flow parameter)

```swift
public enum BranchSelection: Sendable, Hashable {
    case createNew(name: String)
    case useExisting(name: String, source: BranchPickerEntry.Source)
}
```

The `source` field on `useExisting` tells the git layer whether to pass `name` (local) or `origin/<name>` (remote-only) so the right tracking-branch behavior happens.

## Stores

### `RemoteBranchStore` — extended snapshot

`RemoteBranchSnapshot` gains date-bearing fields. Existing callers (`PRStatusStore`, `WorktreeRow`) keep their current views via derived properties — no callsite churn.

```swift
public struct BranchRef: Sendable, Equatable {
    public let name: String
    public let lastCommitDate: Date
}

public struct RemoteBranchSnapshot: Sendable, Equatable {
    public let remoteBranches: [BranchRef]   // refs/remotes/origin/* (date desc)
    public let localBranches: [BranchRef]    // refs/heads/* (date desc)
    public let upstreams: [String: String]   // unchanged

    // legacy convenience for hasRemote / hasOrigin callers
    public var branches: Set<String> { Set(remoteBranches.map(\.name)) }
}
```

`defaultList` switches to:

```
git for-each-ref --format='%(refname:short)\t%(committerdate:iso-strict)\t%(upstream:short)' refs/heads/
git for-each-ref --format='%(refname:short)\t%(committerdate:iso-strict)' refs/remotes/origin
```

Same two calls as today, an extra column kept.

### `PRStatusStore` — second index

Today `infos: [String: PRInfo]` is keyed by worktree path. We add a second observable map keyed by `repoPath → branchName → PRInfo`:

```swift
public private(set) var prsByRepoBranch: [String: [String: PRInfo]] = [:]
```

Populated alongside `infos` inside `applySnapshot`. Same `RepoPRSnapshot` source, two indexes. The picker reads the new map; per-worktree consumers keep reading `infos`. Unsupported-host repos write an empty inner map (matches today's behavior where worktree `infos` stays empty).

### Mounted-branches lookup

No new store. A helper on `RepoEntry` (or extension):

```swift
extension RepoEntry {
    public func branchMountedPath(_ branch: String) -> String? {
        worktrees.first { $0.branch == branch && $0.state.hasOnDiskWorktree }?.path
    }
}
```

`.creating` placeholders intentionally don't count — git would let the user mount the branch even with a placeholder present, and the placeholder may itself fail.

### `BranchPickerViewModel`

A `@MainActor` view model that combines the three sources:

```swift
@MainActor
public struct BranchPickerViewModel {
    public init(
        repo: RepoEntry,
        branchSnapshot: RemoteBranchSnapshot,
        prMap: [String: PRInfo],   // prsByRepoBranch[repo.path] ?? [:]
        filterText: String
    )
    public var entries: [BranchPickerEntry] { get }
}
```

Deterministic logic:

1. Deduplicate by name, preferring `.local` source when both exist.
2. Map each name to a `BranchPickerEntry` using `branchMountedPath`, `prMap[name]`, and `lastCommitDate` from the snapshot.
3. Filter out git sentinel names (`(detached)`, `(bare)`, `(unknown)`, empty) — reuse `RemoteBranchStore.isEligibleLocalBranch`.
4. Filter by `filterText` substring (case-insensitive).
5. Sort: `lastCommitDate` desc, ties broken by name asc.

Tested without SwiftUI.

## Git invocation

`GitWorktreeAdd.add` signature:

```swift
public static func add(
    repoPath: String,
    worktreePath: String,
    branch: BranchSelection,
    startPoint: String?   // ignored when branch == .useExisting
) async throws
```

Argv shapes:

- `.createNew(name)` + non-nil `startPoint` → `git worktree add -b <name> <worktreePath> <startPoint>` (today's behavior).
- `.createNew(name)` + nil `startPoint` → `git worktree add -b <name> <worktreePath>`.
- `.useExisting(name, .local)` → `git worktree add <worktreePath> <name>`.
- `.useExisting(name, .remoteOnly)` → `git worktree add <worktreePath> origin/<name>`. Git creates a local tracking branch as a side effect.

`startPoint` is ignored for `.useExisting` — the existing branch is the start point.

## Flow changes

`AddWorktreeFlow.beginCreate` / `finishCreate` / `add` swap `branchName: String` for `branch: BranchSelection`. One new error:

```swift
case branchAlreadyMounted(at: String)
```

Surfaced from `beginCreate` when `branch == .useExisting(name, _)` and `repo.branchMountedPath(name) != nil`. Message: `"branch '<name>' is already mounted at <path-basename>"`.

The HTTP layer maps `branchAlreadyMounted` to **409 Conflict** with the conflicting path in the body. Other errors map as today.

## Wiring

- `MainWindow.addWorktree` and `AddWorktreeSheet.onSubmit` swap their `branchName` plumbing for `BranchSelection`.
- `WebServerController` reads `existing: Bool?` from the request body and builds either case; default `false` keeps existing clients unchanged.
- iOS `CreateWorktreeClient.Request` gains `existing: Bool?` matching the server contract.
- iOS `AddWorktreeSheetView` adds the segmented mode and the push-to-list flow for "Existing branch".

## Specs (EARS)

New `@spec` IDs under GIT-5.x (creating-a-worktree flow):

- **GIT-5.10** — When `BranchSelection.useExisting(name)` is submitted, the application shall invoke `git worktree add <path> <name>` (no `-b` flag).
- **GIT-5.11** — When the chosen existing branch is already mounted in another worktree of the same repo, the application shall reject the create with `branchAlreadyMounted(at:)` before invoking git.
- **GIT-5.12** — When a `.remoteOnly` branch is selected, the application shall pass `origin/<name>` as the ref so git creates a local tracking branch as a side effect.
- **GIT-5.13** — While `AddWorktreeSheet` is in `.existingBranch` mode, the application shall display branches sorted by last-commit date descending, with branches mounted in another worktree dimmed and unselectable.
- **GIT-5.14** — When a branch row in the existing-branch picker has an associated open PR/MR, the application shall display the PR number and title alongside the branch name.
- **GIT-5.15** — When the user selects a branch from the existing-branch picker, the application shall auto-fill the worktree name with the branch name unless the user has already edited the field.

Tests promote disabled `*Todo.swift` entries to real `@Test`s; `SPECS.md` regenerates via `scripts/generate-specs.py`.

## Tests

- `GitWorktreeAddTests` — table-driven `(BranchSelection, startPoint) → argv`.
- `AddWorktreeFlowTests` — `useExisting` + mounted → `.branchAlreadyMounted`; `useExisting` + free branch → success; round-trip via `add` (blocking path).
- `RemoteBranchStoreTests` — extend with `parseLocalBranchesWithDates` / `parseRemoteBranchesWithDates`; legacy `parseRefs` keeps passing through the derived `branches` property.
- `BranchPickerViewModelTests` — dedup, filter, sort, sentinel exclusion, mounted-detection.
- `WebServerControllerTests` — `existing: true` request → `useExisting` flow; `existing: false` / missing → `createNew` flow (back-compat).
- `AddWorktreeSheetTests` (UI-light, MainActor) — switching to `.existingBranch` mode and selecting a branch auto-fills worktree name when untouched.

## Edge cases

- **Stale snapshot**: branch deleted between picker open and submit → git stderr surfaces through existing `gitFailed(String)` path. No special handling.
- **Same name in local + remote**: dedupe prefers local entry. Local ref is what `git worktree add` will use anyway.
- **`HEAD` symbolic ref**: already stripped by `RemoteBranchStore.parseRefs`. Reuse in picker view model.
- **Unsupported PR host**: `prsByRepoBranch[repoPath]` is empty; rows render without PR annotation.
- **Worktree-name collision in existing mode**: existing `pathCollision` check fires unchanged.
- **First open after adding a repo**: branch snapshot may be empty for one tick; picker shows "Loading branches…" placeholder. `@Observable` refresh kicks in on the next poll.
- **`(detached)` / `(bare)` / `(unknown)`** sentinel branches: filtered by view model.

## Out of scope

- **Tag-based start points** — only branches, no tag picker.
- **Bare/non-origin remotes** — only `origin` remote, matching the rest of Graftty.
- **Cross-repo branch picking** — picker scope is the repo the sheet was opened from.
- **Bulk import** — one worktree per submit.

## Migration

No persisted state changes. No SPECS migration beyond the new `@spec` IDs.
