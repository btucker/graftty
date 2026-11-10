# Sidebar Reorganization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pinned agents become a fixed tile grid that lights up in place, a "+ New worktree" line sits under it, and Needs you (temporary worktrees only) also holds unseen finished turns, on Mac and mobile.

**Architecture:** The shared pieces live in `GrafttyCommandUI` and `GrafttyProtocol` and are unit-tested there: section membership (`WorktreeActivitySections`), tile state and word (`PinnedTile`), waiting counts, dismissal, and a flat pinned list (`MergedWorktreeList`). The Mac (`SidebarView`) and mobile (`WorktreeListContent`) views render those models; a shared tile look lives in each platform's view layer.

**Tech Stack:** Swift 6, SwiftUI, AppKit (Mac), UIKit (mobile), Swift Testing, `scripts/swiftpm test`.

**Spec:** `docs/superpowers/specs/2026-11-09-sidebar-reorganization-design.md`

## Global Constraints

- Follow CLAUDE.md: every behavior change rewrites the `@spec` EARS title in the owning test, RED before GREEN; run `scripts/generate-specs.py`; commit `SPECS.md`.
- No literal `\"` in `@spec` titles (it truncates SPECS.md).
- Tile states are exactly: waiting (orange border), working (moving blue ring; static blue border under Reduce Motion), asleep (faded + moon), idle (faded icon), selected (lighter background). No dots, no git status on tiles.
- Tile word: first segment of the worktree name split on `-`, `_`, `/`, space; default checkout uses its branch.
- Grid columns: as many as fit at a minimum tile width of 56 pt; the grid never scrolls internally.
- The cross-project list (`activitySections` on the phone Projects screen) keeps waiting pinned rows in `needsYou`; only per-project lists exclude them.
- Hosts keep publishing folder metadata (REMOTE-14.3/14.6) so older clients still work; only display and reorder go flat.
- Public repo: commit nothing private.

## Review Focus

1. A pinned agent that asks a question: its tile turns orange, and it does not also appear under Needs you in the same project list. (Task 1 test)
2. A finished turn whose recap has a `need`: listed once, as a question, not twice. (Task 1 test)
3. Dismiss on a row whose only waiting state is an unseen finished turn retires that stop on the host. (Task 3 test)
4. A sleeping host's pinned row: tile shows asleep, never waiting, even with an unseen stop. (Task 4 test)
5. Dragging a pinned tile between two tiles whose names look like a shared folder (`research/a`, `research/b`, `solo`) reorders freely. (Task 5 test)

---

### Task 1: Section membership

**Files:** Modify `Sources/GrafttyCommandUI/WorktreeActivitySections.swift`, `Sources/GrafttyCommandUI/SidebarRowStatus.swift`; Test `Tests/GrafttyCommandUITests/WorktreeActivitySectionsTests.swift`

**Interfaces — Produces:**
- `SidebarRowStatus.waitsForUser: Bool` — true for `.question`, `.notification`, `.whereWeAre(_, isUnread: true)`.
- `WorktreeActivitySections.pinned: [MergedWorktreeRow]` (flat, see Task 5).
- `WorktreeActivitySections.make(pinned:temporary:context:holding:pullsWaitingPins: Bool = true)`. With `pullsWaitingPins == false`, pinned rows always stay in `pinned` in rank order.

- [ ] Rewrite IOS-13.4 test: an unseen stop that asks nothing goes to `needsYou`; IOS-13.1 text: per-project lists group into Needs you, Working, Recent with pinned agents as tiles above; IOS-13.2: with `pullsWaitingPins: false` a pinned row that asks stays in `pinned` and is absent from `needsYou`; keep a test that the default still pulls it (cross-project). Add: a stop with `recap.need` appears once in `needsYou`.
- [ ] Rewrite LAYOUT-2.212 title/test: the Mac sidebar keeps pinned tiles and New worktree fixed above a list holding Needs you, Working and Recent (`placed(in: .pinned)` returns only `pinned`; `.tasks` returns the three lists).
- [ ] Run, see RED. Implement. Run `scripts/swiftpm test --filter WorktreeActivitySectionsTests`, GREEN. Commit.

### Task 2: Waiting counts (LAYOUT-2.210)

**Files:** Create `Sources/GrafttyCommandUI/SidebarWaitingCounts.swift`; Test `Tests/GrafttyCommandUITests/SidebarStatusLineTests.swift` (owns LAYOUT-2.210)

**Interfaces — Produces:** `SidebarWaitingCounts.byProject(_ rows: [WorktreePanes], context: (WorktreePanes) -> SidebarWorktreeContext) -> [String: Int]` — counts worktrees (pinned or not) per `SidebarProjection.projectID` whose resolved status `waitsForUser`.

- [ ] Rewrite LAYOUT-2.210: the count is every worktree waiting (question, notification, unseen finished turn), pinned or not. Test with one question row, one unseen-stop row, one idle row → 2.
- [ ] Implement; Mac rail and mobile per-project counts use it instead of `SidebarActivityCounts.attentionByProject`. Commit.

### Task 3: Dismiss clears unseen finishes (LAYOUT-2.216/2.218)

**Files:** Modify `Sources/GrafttyCommandUI/SidebarAttentionDismissal.swift`; Test `Tests/GrafttyCommandUITests/SidebarAttentionDismissalTests.swift`

- [ ] Rewrite LAYOUT-2.216 test: available when `context.pending` is non-empty **or** the row has an unseen stop and is not running. Rewrite LAYOUT-2.218: `requests(for:supportsExactAcknowledgement: true)` also returns `.acknowledgeOccurrence(worktreeID: path, paneID: nil, occurrence: unseenAgentStop.occurrence)` for that stop, once (no duplicate when the stop is also pending). The host-side `SidebarHostNavigation.acknowledge` already clears `unseenAgentStop` for that request.
- [ ] RED, implement, GREEN, commit.

### Task 4: Tile model

**Files:** Create `Sources/GrafttyCommandUI/PinnedTile.swift`; Test `Tests/GrafttyCommandUITests/PinnedTileTests.swift`

**Interfaces — Produces:**
- `enum PinnedTileState { case waiting, working, asleep, idle }`, `static func resolve(status: SidebarRowStatus, isCached: Bool) -> PinnedTileState`.
- `enum PinnedTile { static func word(name: String, isMainCheckout: Bool, branch: String) -> String; static func accessibilityLabel(name: String, host: String?, state: PinnedTileState) -> String; static let minimumWidth: CGFloat = 56 }`.

- [ ] Tests (new LAYOUT-2.225 tile states, LAYOUT-2.226 tile word): `crash-report`→`crash`, `ci_watch`→`ci`, `research/notes`→`research`, `a b`→`a`, main checkout uses branch; cached + unseen stop → `.asleep`; `.whereWeAre(isUnread: false)` → `.idle`.
- [ ] RED, implement, GREEN, commit.

### Task 5: Flat pinned list, host always named

**Files:** Modify `Sources/GrafttyProtocol/MergedWorktreeList.swift`, `Sources/GrafttyProtocol/SidebarMergedRows.swift`, `Sources/GrafttyKit/Model/SidebarHostNavigation.swift` (`moveWorktree`), `Sources/Graftty/Views/RemoteMacsSection.swift` (`areSiblings`); Tests `Tests/GrafttyProtocolTests/MergedWorktreeListTests.swift`, `Tests/GrafttyTests/SidebarMergedRowsTests.swift`, `Tests/GrafttyTests/Views/WorktreeDropReorderTests.swift`, `Tests/GrafttyKitTests/Model/SidebarWorktreeHierarchyTests.swift`

**Interfaces — Produces:** `MergedWorktreeList.build(...) -> (pinned: [MergedWorktreeRow], temporary: [MergedWorktreeRow])`; `MergedWorktreeNode` removed; `leafName == relativeName`; `showsHostLabel` true for every row on a host other than this device in a several-host project.

- [ ] Rewrite LAYOUT-2.221: remote rows name their host always. Rewrite LAYOUT-2.34 as: dropping a pinned row onto any pinned row reorders the flat list (`research/lead` onto `solo` succeeds). Delete LAYOUT-2.35/2.36/2.37 tests. Rewrite LAYOUT-2.32/2.33 titles to say the host publishes the inferred folder in worktree metadata for older clients (tests unchanged).
- [ ] RED, implement, GREEN (`scripts/swiftpm test`), commit.

### Task 6: Mac tile grid and New worktree line

**Files:** Create `Sources/Graftty/Views/PinnedTileGrid.swift`; Modify `Sources/Graftty/Views/SidebarView.swift`, `Sources/Graftty/Views/SidebarWorktreeViewport.swift`, `Sources/Graftty/Views/RemoteMacsSection.swift` (tile presentation of `SingleRow`); Tests `Tests/GrafttyTests/Views/SidebarScrollLayoutTests.swift`, `Tests/GrafttyKitTests/Model/SidebarPinnedTests.swift`, `Tests/GrafttyTests/Views/PinnedAgentEditingTests.swift`, `Tests/GrafttyCommandUITests/ProjectWorktreeColumnTests.swift`

**Interfaces — Consumes:** Tasks 1, 4. **Produces:** `PinnedTileView(icon:word:hostBadge:state:isSelected:hover:)`, `PinnedTileGrid` (adaptive `LazyVGrid`, min 56 pt).

- [ ] Viewport: drop the resizable divider and height state; top content takes its natural height (LAYOUT-2.89 rewrite: tiles and New worktree stay fixed above the list in rail mode; in no-rail mode each project group holds its own grid, line, and sections).
- [ ] Tiles: local tiles use `buildWorktreeMenu` and `worktreeReorderTarget`-style drag; remote tiles render through `RemoteMacsSection` with `SingleRow.isTile = true` to reuse `remoteWorktreeMenu`, dismissal, and drag payload. Drop places before/after by x. Dropping a temporary local row on the grid pins it (`PinnedWorktreeDropTarget`, LAYOUT-2.113 rewrite to say the tile grid).
- [ ] Hover card (popover on hover after a short delay): full name, host, status line.
- [ ] "+ New worktree" line replaces the floating button; same `addWorktreeToSelectedProject` / `canAddWorktree`.
- [ ] Remove the Pinned header and collapse (delete LAYOUT-2.106 test; rewrite LAYOUT-2.103, 2.112, 2.115 titles to the tile grid).
- [ ] `scripts/swiftpm test`, build the app, commit.

### Task 7: Mac row layout (DIVERGE-1.1, LAYOUT-2.81)

**Files:** Modify `Sources/Graftty/Views/WorktreeRow.swift`, `Sources/Graftty/Views/WorktreeBlock.swift`, `Sources/Graftty/Views/RemoteMacsSection.swift`; Tests `Tests/GrafttyTests/Views/WorktreeRowPRBadgeTests.swift`, `Tests/GrafttyTests/Specs/DivergeTodo.swift`

- [ ] `WorktreeRow.leadingSequence` → `[identity, label, prBadge]` with the badge trailing; LAYOUT-2.81 text says the PR badge is right-aligned on the name line. Divergence moves to line 2, trailing, beside the status line; DIVERGE-1.1 rewritten and promoted from the Todo inventory to a test of a `WorktreeRow.trailingLine` helper.
- [ ] GREEN, commit.

### Task 8: Mobile per-project list

**Files:** Modify `Sources/GrafttyMobileKit/UI/WorktreeListContent.swift`; Create `Sources/GrafttyMobileKit/UI/PinnedTileGrid.swift`

- [ ] Per-project list: tile grid (tap opens, long-press menu reuses the row's menu, drag reorders via the existing rank writes), "+ New worktree" row replacing the toolbar `+`, then Needs you / Working / Recent from `make(..., pullsWaitingPins: false)`. Cross-project callers keep the default.
- [ ] Counts from Task 2. Compile for iOS Simulator (`xcodebuild -scheme GrafttyMobile -destination 'generic/platform=iOS Simulator' build`), commit.

### Task 9: Finish

- [ ] `scripts/generate-specs.py`; `scripts/swiftpm test`; `/code-review xhigh --fix`; open PR.
