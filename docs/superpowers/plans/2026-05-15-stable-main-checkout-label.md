# Stable Main-Checkout Sidebar Label Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The main-checkout sidebar row's primary label resolves to the repo's default branch (stable across local `git checkout`), with the current HEAD shown as a dimmed secondary caption when it diverges. The home icon stays even when a PR is associated with the main checkout.

**Architecture:** A new field on `RemoteBranchSnapshot` (`defaultBranch: String?`) carries the result of `git symbolic-ref --short refs/remotes/origin/HEAD`, polled concurrently with the existing remote/local branch listings. A new `RepoEntry.defaultBranchHint` (snapshot at add-repo time) acts as fallback. `SidebarWorktreeLabel.text` swaps the main-checkout return path from `worktree.displayBranch` to the resolved default. `WorktreeRowIcon.symbolName` short-circuits on `isMainCheckout` before the existing PR-flip. The existing dedup at `WorktreeRow.swift:361` automatically renders the current-HEAD caption when it differs.

**Tech Stack:** Swift 5.10 (Swift Testing), `@Observable` on `RemoteBranchStore`, async let for concurrent git invocations via `GitRunner.run(args:at:)`.

**Spec:** `docs/superpowers/specs/2026-05-15-stable-main-checkout-label-design.md`

---

## File Structure

**Modify:**
- `Sources/GrafttyKit/Git/RemoteBranchStore.swift` — extend `RemoteBranchSnapshot`, add `parseDefaultBranchForTesting`, extend `defaultList` to issue the `symbolic-ref` call concurrently.
- `Sources/GrafttyKit/Model/RepoEntry.swift` — add `defaultBranchHint` field, extend `CodingKeys`, extend custom `init(from:)`.
- `Sources/GrafttyKit/Model/SidebarWorktreeLabel.swift` — extend `text(for:inRepoAtPath:siblingPaths:)` with new `defaultBranch:` parameter; swap main-checkout return path.
- `Sources/GrafttyProtocol/WorktreeRowIcon.swift` — reorder conditions so `isMainCheckout` short-circuits before `hasPR`.
- `Sources/Graftty/Views/MainWindow.swift` — populate `defaultBranchHint` in `addRepoFromPath` (line 869); thread `defaultBranch` at `worktreeDisplayName` (line 256) and the move-menu path (line 777).
- `Sources/Graftty/Views/SidebarView.swift` — resolve and thread `defaultBranch` through `repoSection` (line 122) → `worktreeBlock`.
- `Sources/Graftty/Terminal/PaneMoveMenuBuilder.swift` — thread `defaultBranch` through `currentWorktreeItem` (line 91) and `siblingsSubmenu` (line 119).

**Modify (tests):**
- `Tests/GrafttyKitTests/Git/RemoteBranchStoreTests.swift` — parser tests for `parseDefaultBranchForTesting`.
- `Tests/GrafttyKitTests/Model/RepoEntryTests.swift` (create if missing) — migration test for pre-feature decode.
- `Tests/GrafttyKitTests/Model/SidebarWorktreeLabelTests.swift` — main-checkout returns resolved default; falls back to `"main"`; non-main unchanged.
- `Tests/GrafttyKitTests/Model/WorktreeRowIconTests.swift` — `isMainCheckout=true, hasPR=true` returns `"house"` (update existing test that asserts the opposite).

---

## Task 1: `RemoteBranchSnapshot.defaultBranch` + parser

**Files:**
- Modify: `Sources/GrafttyKit/Git/RemoteBranchStore.swift`
- Modify: `Tests/GrafttyKitTests/Git/RemoteBranchStoreTests.swift`

- [ ] **Step 1: Write the failing parser tests**

Append to `Tests/GrafttyKitTests/Git/RemoteBranchStoreTests.swift`:

```swift
@Test func parseDefaultBranchStripsOriginPrefix() {
    #expect(RemoteBranchStore.parseDefaultBranchForTesting("origin/main\n") == "main")
}

@Test func parseDefaultBranchHandlesAlternateRemoteName() {
    #expect(RemoteBranchStore.parseDefaultBranchForTesting("upstream/trunk\n") == "trunk")
}

@Test func parseDefaultBranchReturnsNilForEmpty() {
    #expect(RemoteBranchStore.parseDefaultBranchForTesting("") == nil)
    #expect(RemoteBranchStore.parseDefaultBranchForTesting("\n") == nil)
}

@Test func parseDefaultBranchReturnsRawWhenNoSlash() {
    // Defensive: git would not normally emit this, but if it does we
    // prefer to surface *something* over nil.
    #expect(RemoteBranchStore.parseDefaultBranchForTesting("trunk") == "trunk")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RemoteBranchStoreTests`
Expected: FAIL — `parseDefaultBranchForTesting` is not defined.

- [ ] **Step 3: Add the field to `RemoteBranchSnapshot`**

In `Sources/GrafttyKit/Git/RemoteBranchStore.swift`, modify `RemoteBranchSnapshot`:

```swift
public struct RemoteBranchSnapshot: Sendable, Equatable {
    public let remoteBranches: [BranchRef]
    public let localBranches: [BranchRef]
    public let upstreams: [String: String]
    /// @spec LAYOUT-2.29
    /// Repository's default branch as resolved from
    /// `git symbolic-ref --short refs/remotes/origin/HEAD`,
    /// stripped of the `<remote>/` prefix. `nil` when HEAD is
    /// unset on origin or the lookup fails.
    public let defaultBranch: String?

    public init(
        remoteBranches: [BranchRef] = [],
        localBranches: [BranchRef] = [],
        upstreams: [String: String] = [:],
        defaultBranch: String? = nil
    ) {
        self.remoteBranches = remoteBranches
        self.localBranches = localBranches
        self.upstreams = upstreams
        self.defaultBranch = defaultBranch
    }

    public var branches: Set<String> { Set(remoteBranches.map(\.name)) }

    public init(branches: Set<String>, upstreams: [String: String] = [:]) {
        self.remoteBranches = branches.map { BranchRef(name: $0, lastCommitDate: .distantPast) }
        self.localBranches = []
        self.upstreams = upstreams
        self.defaultBranch = nil
    }
}
```

- [ ] **Step 4: Add the parser to `RemoteBranchStore`**

In the same file, near the other `parse*` helpers (before `defaultList`):

```swift
nonisolated static func parseDefaultBranch(_ output: String) -> String? {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let slash = trimmed.firstIndex(of: "/") {
        return String(trimmed[trimmed.index(after: slash)...])
    }
    return trimmed
}

nonisolated static func parseDefaultBranchForTesting(_ output: String) -> String? {
    parseDefaultBranch(output)
}
```

- [ ] **Step 5: Extend `defaultList` to resolve origin/HEAD concurrently**

Replace the `defaultList` body:

```swift
public nonisolated static let defaultList: ListFunction = { repoPath in
    async let remotesTask = GitRunner.run(
        args: ["for-each-ref", "--format=%(refname:short)\t%(committerdate:iso-strict)", "refs/remotes/origin"],
        at: repoPath
    )
    async let headsTask = GitRunner.run(
        args: ["for-each-ref", "--format=%(refname:short)\t%(committerdate:iso-strict)\t%(upstream:short)", "refs/heads/"],
        at: repoPath
    )
    async let defaultBranchTask = GitRunner.run(
        args: ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
        at: repoPath
    )
    let (remotes, heads) = try await (remotesTask, headsTask)
    let defaultBranch = (try? await defaultBranchTask).flatMap(parseDefaultBranch)
    return RemoteBranchSnapshot(
        remoteBranches: parseRemoteBranchesWithDates(remotes),
        localBranches: parseLocalBranchesWithDates(heads),
        upstreams: parseUpstreams(heads),
        defaultBranch: defaultBranch
    )
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter RemoteBranchStoreTests`
Expected: PASS, no regressions in existing parser tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Git/RemoteBranchStore.swift Tests/GrafttyKitTests/Git/RemoteBranchStoreTests.swift
git commit -m "feat(git): resolve origin/HEAD into RemoteBranchSnapshot.defaultBranch"
```

---

## Task 2: `RepoEntry.defaultBranchHint` + migration

**Files:**
- Modify: `Sources/GrafttyKit/Model/RepoEntry.swift`
- Create: `Tests/GrafttyKitTests/Model/RepoEntryTests.swift`

- [ ] **Step 1: Write the failing migration test**

Create `Tests/GrafttyKitTests/Model/RepoEntryTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("RepoEntry")
struct RepoEntryTests {
    @Test func decodesPreFeatureBlobWithoutDefaultBranchHint() throws {
        // Pre-feature state.json blob shape — no `defaultBranchHint` key.
        let preFeatureJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "path": "/repo",
            "displayName": "repo",
            "isCollapsed": false,
            "worktrees": [],
            "isGitTracked": true
        }
        """
        let data = preFeatureJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RepoEntry.self, from: data)
        #expect(decoded.defaultBranchHint == nil)
        #expect(decoded.path == "/repo")
    }

    @Test func decodesNewBlobWithDefaultBranchHint() throws {
        let json = """
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "path": "/repo",
            "displayName": "repo",
            "isCollapsed": false,
            "worktrees": [],
            "isGitTracked": true,
            "defaultBranchHint": "trunk"
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RepoEntry.self, from: data)
        #expect(decoded.defaultBranchHint == "trunk")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RepoEntryTests`
Expected: FAIL — `defaultBranchHint` does not exist.

- [ ] **Step 3: Add the field with migration**

In `Sources/GrafttyKit/Model/RepoEntry.swift`:

```swift
public struct RepoEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var path: String
    public var displayName: String
    public var isCollapsed: Bool
    public var worktrees: [WorktreeEntry]
    public var bookmark: Data?
    public var isGitTracked: Bool
    /// Default branch observed when the repo was first added to
    /// Graftty. Used as a fallback for the main-checkout row label
    /// when `RemoteBranchSnapshot.defaultBranch` is not yet resolved
    /// (no remote, network failure, fresh launch before first poll).
    /// Pre-feature `state.json` blobs lack this key —
    /// `init(from:)` defaults it to `nil`.
    public var defaultBranchHint: String?

    public init(
        path: String,
        displayName: String,
        isCollapsed: Bool = false,
        worktrees: [WorktreeEntry] = [],
        bookmark: Data? = nil,
        isGitTracked: Bool = true,
        defaultBranchHint: String? = nil
    ) {
        self.id = UUID()
        self.path = path
        self.displayName = displayName
        self.isCollapsed = isCollapsed
        self.worktrees = worktrees
        self.bookmark = bookmark
        self.isGitTracked = isGitTracked
        self.defaultBranchHint = defaultBranchHint
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, displayName, isCollapsed, worktrees, bookmark, isGitTracked, defaultBranchHint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.path = try container.decode(String.self, forKey: .path)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        self.worktrees = try container.decode([WorktreeEntry].self, forKey: .worktrees)
        self.bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
        self.isGitTracked = try container.decodeIfPresent(Bool.self, forKey: .isGitTracked) ?? true
        self.defaultBranchHint = try container.decodeIfPresent(String.self, forKey: .defaultBranchHint)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RepoEntryTests`
Expected: PASS.

Also run the full kit suite to verify nothing else broke:
Run: `swift test --filter GrafttyKitTests`
Expected: PASS (any pre-existing failures unrelated to this change).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Model/RepoEntry.swift Tests/GrafttyKitTests/Model/RepoEntryTests.swift
git commit -m "feat(model): RepoEntry.defaultBranchHint with codable migration"
```

---

## Task 3: Populate `defaultBranchHint` at add-repo time

**Files:**
- Modify: `Sources/Graftty/Views/MainWindow.swift` (line 869)

This change has no direct unit test — it threads a value into a SwiftUI flow. The integration is validated indirectly by the label test in Task 5 (which exercises `defaultBranchHint` via the snapshot). Bundle this with a compile check.

- [ ] **Step 1: Modify `addRepoFromPath`**

In `Sources/Graftty/Views/MainWindow.swift`, locate the `RepoEntry(...)` construction starting at line 869 and replace with:

```swift
// Capture the main-checkout branch at add time so the sidebar
// has a stable default-branch label even before the first
// origin/HEAD poll lands (or for repos with no remote at all).
let mainCheckoutBranch = discovered.first(where: { $0.path == repoPath })?.branch
let repo = RepoEntry(
    path: repoPath,
    displayName: displayName,
    worktrees: worktrees,
    bookmark: bookmark,
    defaultBranchHint: mainCheckoutBranch
)
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: clean build, no warnings about unused vars or missing arguments.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Views/MainWindow.swift
git commit -m "feat(repo): capture defaultBranchHint when adding a repo"
```

---

## Task 4: `WorktreeRowIcon` — main checkout always uses `house`

**Files:**
- Modify: `Sources/GrafttyProtocol/WorktreeRowIcon.swift`
- Modify: `Tests/GrafttyKitTests/Model/WorktreeRowIconTests.swift`

- [ ] **Step 1: Update the test that asserts the *current* (about-to-change) behavior**

In `Tests/GrafttyKitTests/Model/WorktreeRowIconTests.swift`, replace `mainCheckoutWithPRStillUsesPullSymbol` with the inverse assertion:

```swift
@Test("@spec LAYOUT-2.27: The application shall render the `house` SF Symbol on the main-checkout sidebar row regardless of whether a PR is associated with that worktree, so the home affordance never disappears.")
func mainCheckoutAlwaysUsesHouseSymbolEvenWithPR() {
    // The home icon is the only persistent visual indicator that
    // identifies the main checkout row. Flipping it to the PR glyph
    // when a PR exists on the main branch would erase the only
    // stable "home" cue once the row's text label also drifts to
    // the current branch.
    #expect(WorktreeRowIcon.symbolName(isMainCheckout: true, hasPR: true) == "house")
}
```

- [ ] **Step 2: Run tests to verify the new one fails**

Run: `swift test --filter WorktreeRowIconTests`
Expected: FAIL — current implementation returns `"arrow.triangle.pull"`.

- [ ] **Step 3: Reorder conditions in `WorktreeRowIcon.symbolName`**

Replace `Sources/GrafttyProtocol/WorktreeRowIcon.swift` body:

```swift
import Foundation

public enum WorktreeRowIcon {
    /// SF Symbol name for the leading icon in a worktree's sidebar row.
    ///
    /// Main checkouts always show `house` — it's the only persistent
    /// visual indicator that the row is the repo's home base, and
    /// flipping it to a PR glyph would erase that cue (the `#NNN` PR
    /// badge text on the same row already conveys PR-ness). For
    /// linked worktrees, `arrow.triangle.pull` (the universal PR/MR
    /// glyph) appears once a PR is associated, otherwise
    /// `arrow.triangle.branch`.
    public static func symbolName(isMainCheckout: Bool, hasPR: Bool) -> String {
        if isMainCheckout { return "house" }
        if hasPR { return "arrow.triangle.pull" }
        return "arrow.triangle.branch"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WorktreeRowIconTests`
Expected: PASS — all four tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyProtocol/WorktreeRowIcon.swift Tests/GrafttyKitTests/Model/WorktreeRowIconTests.swift
git commit -m "feat(sidebar): main-checkout row always uses house icon (LAYOUT-2.27)"
```

---

## Task 5: `SidebarWorktreeLabel.text` + thread `defaultBranch` through call sites

This is one atomic change because the signature update breaks all callers — they must update together to keep the build green.

**Files:**
- Modify: `Sources/GrafttyKit/Model/SidebarWorktreeLabel.swift`
- Modify: `Sources/Graftty/Views/SidebarView.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift` (lines 256 and 777)
- Modify: `Sources/Graftty/Terminal/PaneMoveMenuBuilder.swift` (lines 91 and 119)
- Modify: `Tests/GrafttyKitTests/Model/SidebarWorktreeLabelTests.swift`

- [ ] **Step 1: Write failing tests for the new label behavior**

Append to `Tests/GrafttyKitTests/Model/SidebarWorktreeLabelTests.swift`:

```swift
@Test("@spec LAYOUT-2.25: The application shall display the repository's resolved default branch name as the main-checkout sidebar row's primary label, regardless of the worktree's current HEAD.")
func mainCheckoutLabelUsesResolvedDefaultBranch() {
    let entry = WorktreeEntry(path: "/repo", branch: "feature-x")
    let label = SidebarWorktreeLabel.text(
        for: entry,
        inRepoAtPath: "/repo",
        siblingPaths: ["/repo"],
        defaultBranch: "trunk"
    )
    #expect(label == "trunk")
}

@Test("@spec LAYOUT-2.28: The application shall fall back to `\"main\"` for the main-checkout row label when no default branch has been resolved.")
func mainCheckoutLabelFallsBackToMain() {
    let entry = WorktreeEntry(path: "/repo", branch: "feature-x")
    let label = SidebarWorktreeLabel.text(
        for: entry,
        inRepoAtPath: "/repo",
        siblingPaths: ["/repo"],
        defaultBranch: nil
    )
    #expect(label == "main")
}

@Test func linkedWorktreeLabelIgnoresDefaultBranchArgument() {
    let entry = WorktreeEntry(path: "/repo/.worktrees/feature-x", branch: "feature/x")
    let label = SidebarWorktreeLabel.text(
        for: entry,
        inRepoAtPath: "/repo",
        siblingPaths: ["/repo", "/repo/.worktrees/feature-x"],
        defaultBranch: "trunk"
    )
    #expect(label == "feature-x")
}
```

- [ ] **Step 2: Update existing tests in the same file to pass the new parameter**

The existing tests (`mainCheckoutUsesSanitizedDisplayBranch`, `mainCheckoutWithCleanBranchReturnsBranch`, `linkedWorktreeUsesDisplayName`, `repoLabelsMatchPerRowLabels`) call `SidebarWorktreeLabel.text` without `defaultBranch`. They will break the build once the signature changes.

Update each call site as follows:

- `mainCheckoutUsesSanitizedDisplayBranch`: This test asserts BIDI-stripping behavior on the main-checkout branch label. Under the new design the main-checkout label is the *default branch* (which is application-resolved, not user-controlled), not the worktree's branch. The BIDI risk for the main-checkout label is gone — but the test should still pass for the secondary caption rendered by `WorktreeRow`, which IS user-controlled (`entry.displayBranch`). The label helper test below is no longer the right place to assert this. Replace the test body:

```swift
@Test func mainCheckoutLabelDoesNotReadWorktreeBranch() {
    // Under the new design, the main-checkout label is the
    // resolved default branch, not the worktree's current branch.
    // A BIDI-override scalar in `entry.branch` cannot reach this
    // label at all. (The secondary caption in WorktreeRow.swift
    // still goes through `entry.displayBranch`, which strips
    // BIDI overrides per GIT-2.10.)
    let entry = WorktreeEntry(path: "/repo", branch: "feat\u{202E}lanigiro")
    let label = SidebarWorktreeLabel.text(
        for: entry,
        inRepoAtPath: "/repo",
        siblingPaths: ["/repo"],
        defaultBranch: "main"
    )
    #expect(label == "main")
}
```

- `mainCheckoutWithCleanBranchReturnsBranch`: rewrite to test the default-branch passthrough explicitly:

```swift
@Test func mainCheckoutReturnsResolvedDefaultBranch() {
    let entry = WorktreeEntry(path: "/repo", branch: "main")
    let label = SidebarWorktreeLabel.text(
        for: entry,
        inRepoAtPath: "/repo",
        siblingPaths: ["/repo"],
        defaultBranch: "main"
    )
    #expect(label == "main")
}
```

- `linkedWorktreeUsesDisplayName`: add `defaultBranch: nil`:

```swift
@Test func linkedWorktreeUsesDisplayName() {
    let entry = WorktreeEntry(path: "/repo/.worktrees/feature-x", branch: "feature/x")
    let label = SidebarWorktreeLabel.text(
        for: entry,
        inRepoAtPath: "/repo",
        siblingPaths: ["/repo", "/repo/.worktrees/feature-x"],
        defaultBranch: nil
    )
    #expect(label == "feature-x")
}
```

- `repoLabelsMatchPerRowLabels`: extend both the `texts(for:inRepoAtPath:)` and `text(for:inRepoAtPath:siblingPaths:)` calls with a `defaultBranch` parameter:

```swift
@Test func repoLabelsMatchPerRowLabels() {
    let main = WorktreeEntry(path: "/repo", branch: "main")
    let nested = WorktreeEntry(path: "/repo/.worktrees/feature-x", branch: "feature/x")
    let sibling = WorktreeEntry(path: "/repo/.other/feature-x", branch: "feature/x-alt")
    let worktrees = [main, nested, sibling]

    let labels = SidebarWorktreeLabel.texts(
        for: worktrees,
        inRepoAtPath: "/repo",
        defaultBranch: "main"
    )
    let siblingPaths = worktrees.map(\.path)

    for worktree in worktrees {
        #expect(labels[worktree.id] == SidebarWorktreeLabel.text(
            for: worktree,
            inRepoAtPath: "/repo",
            siblingPaths: siblingPaths,
            defaultBranch: "main"
        ))
    }
}
```

Also update the `@Suite` doc text in this file — it currently cites `GIT-2.10` for the main-checkout label sanitization. The main-checkout label no longer reads `displayBranch`, so the GIT-2.10 concern no longer applies to this helper for that surface. Edit the suite description to remove the main-checkout reference, but keep the BIDI rationale for the secondary caption that the row still renders (which still flows through `displayBranch`). Replace the suite description text with:

```swift
@Suite("""
SidebarWorktreeLabel

The shared label helper for sidebar-adjacent worktree surfaces (row
label + right-click "Move to <name>" menu items). For linked
worktrees, the label is derived from the path basename. For the
main checkout, the label is the resolved default branch name —
application-controlled, never user-controlled — so BIDI-override
sanitization (GIT-2.10) is unnecessary on this surface for the
main-checkout path. The secondary caption rendered by `WorktreeRow`
still routes user-controlled `entry.branch` through `displayBranch`,
preserving GIT-2.10 for the row's dimmed current-HEAD line.
""")
```

- [ ] **Step 3: Run tests to verify they fail to compile**

Run: `swift test --filter SidebarWorktreeLabelTests`
Expected: BUILD FAIL — `text(for:inRepoAtPath:siblingPaths:defaultBranch:)` does not exist.

- [ ] **Step 4: Update `SidebarWorktreeLabel.text` and `texts`**

Replace `Sources/GrafttyKit/Model/SidebarWorktreeLabel.swift`:

```swift
import Foundation

/// Shared label rule for sidebar-adjacent worktree surfaces (row
/// label + right-click "Move to <name>" menu items).
///
/// Main checkout: label is the repo's resolved default branch
/// (passed in by callers, who chain
/// `snapshot.defaultBranch ?? repo.defaultBranchHint`). Falls back
/// to `"main"` so the UI never goes blank. Stable across local
/// `git checkout`.
///
/// Linked worktrees: label is the directory basename, possibly
/// disambiguated against same-named siblings via
/// `WorktreeEntry.displayName(amongSiblingPaths:)`.
public enum SidebarWorktreeLabel {
    public static func texts(
        for worktrees: [WorktreeEntry],
        inRepoAtPath repoPath: String,
        defaultBranch: String?
    ) -> [WorktreeEntry.ID: String] {
        let siblingPaths = worktrees.map(\.path)
        return Dictionary(
            uniqueKeysWithValues: worktrees.map { worktree in
                (
                    worktree.id,
                    text(
                        for: worktree,
                        inRepoAtPath: repoPath,
                        siblingPaths: siblingPaths,
                        defaultBranch: defaultBranch
                    )
                )
            }
        )
    }

    public static func text(
        for worktree: WorktreeEntry,
        inRepoAtPath repoPath: String,
        siblingPaths: [String],
        defaultBranch: String?
    ) -> String {
        if worktree.path == repoPath {
            return defaultBranch ?? "main"
        }
        return worktree.displayName(amongSiblingPaths: siblingPaths)
    }
}
```

- [ ] **Step 5: Update callers in production code**

`Sources/Graftty/Views/SidebarView.swift` — locate the `repoSection` body around line 122-125. The current call:

```swift
let worktreeLabels = SidebarWorktreeLabel.texts(
    for: repo.worktrees,
    inRepoAtPath: repo.path
)
```

Replace with:

```swift
let resolvedDefaultBranch =
    remoteBranchStore.branchesByRepo[repo.path]?.defaultBranch
    ?? repo.defaultBranchHint
let worktreeLabels = SidebarWorktreeLabel.texts(
    for: repo.worktrees,
    inRepoAtPath: repo.path,
    defaultBranch: resolvedDefaultBranch
)
```

And the fallback call near line 141-145 (`SidebarWorktreeLabel.text(...)` inside the `?? `) — extend with `defaultBranch: resolvedDefaultBranch`:

```swift
displayName: worktreeLabels[worktree.id] ?? SidebarWorktreeLabel.text(
    for: worktree,
    inRepoAtPath: repo.path,
    siblingPaths: repo.worktrees.map(\.path),
    defaultBranch: resolvedDefaultBranch
)
```

`Sources/Graftty/Views/MainWindow.swift` line 256 (`worktreeDisplayName`):

```swift
private var worktreeDisplayName: String? {
    guard let repo = selectedRepo, let wt = selectedWorktree else { return nil }
    let defaultBranch =
        remoteBranchStore.branchesByRepo[repo.path]?.defaultBranch
        ?? repo.defaultBranchHint
    return SidebarWorktreeLabel.text(
        for: wt,
        inRepoAtPath: repo.path,
        siblingPaths: repo.worktrees.map(\.path),
        defaultBranch: defaultBranch
    )
}
```

Note: `worktreeDisplayName` currently calls `wt.displayName(amongSiblingPaths:)` directly. Replace it with the `SidebarWorktreeLabel.text` call shown above so the breadcrumb matches the sidebar exactly when the active worktree IS the main checkout.

Also `Sources/Graftty/Views/MainWindow.swift` around line 777 (the move-menu label lookup inside `wt.displayName(amongSiblingPaths:)`). Replace:

```swift
let label = wt.displayName(amongSiblingPaths: siblingPaths)
```

with:

```swift
let defaultBranch =
    remoteBranchStore.branchesByRepo[repo.path]?.defaultBranch
    ?? repo.defaultBranchHint
let label = SidebarWorktreeLabel.text(
    for: wt,
    inRepoAtPath: repo.path,
    siblingPaths: siblingPaths,
    defaultBranch: defaultBranch
)
```

`Sources/Graftty/Terminal/PaneMoveMenuBuilder.swift` line 91 (inside `currentWorktreeItem`):

```swift
let label = SidebarWorktreeLabel.text(
    for: match.worktree,
    inRepoAtPath: match.repo.path,
    siblingPaths: match.repo.worktrees.map(\.path),
    defaultBranch: context.defaultBranch(for: match.repo.path)
)
```

And line 119 (`siblingsSubmenu`):

```swift
let label = SidebarWorktreeLabel.text(
    for: sibling,
    inRepoAtPath: repo.path,
    siblingPaths: allPaths,
    defaultBranch: context.defaultBranch(for: repo.path)
)
```

You'll need to add a `defaultBranch(for:)` lookup to `PaneMoveMenuContext`. Read `Sources/Graftty/Terminal/PaneMoveMenuBuilder.swift` to find the `PaneMoveMenuContext` struct (around line 8-15), then add:

```swift
struct PaneMoveMenuContext {
    let cwdMatch: (repo: RepoEntry, worktree: WorktreeEntry)?
    let currentRepo: RepoEntry
    let currentWorktree: WorktreeEntry
    let defaultBranchesByRepoPath: [String: String?]

    func defaultBranch(for repoPath: String) -> String? {
        defaultBranchesByRepoPath[repoPath] ?? nil
    }
}
```

(Adjust to match the actual struct shape you find — preserve all existing fields, just add the new one.)

The site that constructs `PaneMoveMenuContext` (likely `Sources/Graftty/Terminal/SurfaceContextMenu.swift` or `GrafttyApp.swift`) needs to populate this dictionary. Grep for `PaneMoveMenuContext(` and update the construction:

```swift
let defaultBranches: [String: String?] = Dictionary(
    uniqueKeysWithValues: repos.map { repo in
        (repo.path,
         remoteBranchStore.branchesByRepo[repo.path]?.defaultBranch ?? repo.defaultBranchHint)
    }
)
PaneMoveMenuContext(
    cwdMatch: match,
    currentRepo: currentRepo,
    currentWorktree: currentWorktree,
    defaultBranchesByRepoPath: defaultBranches
)
```

- [ ] **Step 6: Build and verify tests pass**

Run: `swift build`
Expected: clean build.

Run: `swift test --filter SidebarWorktreeLabelTests`
Expected: PASS, including the three new tests.

Run: `swift test`
Expected: PASS for the kit suite. Some Graftty app target tests may have unrelated pre-existing failures — confirm any failures are pre-existing on `main`, not introduced by this change.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Model/SidebarWorktreeLabel.swift \
        Sources/Graftty/Views/SidebarView.swift \
        Sources/Graftty/Views/MainWindow.swift \
        Sources/Graftty/Terminal/PaneMoveMenuBuilder.swift \
        Sources/Graftty/Terminal/SurfaceContextMenu.swift \
        Sources/Graftty/GrafttyApp.swift \
        Tests/GrafttyKitTests/Model/SidebarWorktreeLabelTests.swift
git commit -m "feat(sidebar): main-checkout label = resolved default branch (LAYOUT-2.25, 2.28)"
```

(Only stage the GrafttyApp.swift / SurfaceContextMenu.swift files if they actually changed — `git status` first.)

---

## Task 6: Regenerate `SPECS.md`

**Files:**
- Modify: `SPECS.md` (auto-generated)

- [ ] **Step 1: Run the generator**

Run: `uv run scripts/generate-specs.py`
Expected: regenerates `SPECS.md` to include the new LAYOUT-2.25, 2.26, 2.27, 2.28, 2.29 entries.

(LAYOUT-2.26 is the "secondary caption when current branch differs from default" requirement. It's enforced by the existing `WorktreeRow.swift:361` dedup; no new test code is needed for the structural behavior, but the `@spec` annotation has to live somewhere. Add it as a `@Test(.disabled("structural — exercised at integration"))` entry in `Tests/GrafttyTests/Specs/LayoutTodo.swift` BEFORE running the generator. Alternatively, attach it as a `@spec` doc comment on the existing `branchLabel` view in `WorktreeRow.swift` — preferred, since the comment then sits right next to the code that satisfies it.)

Add to `Sources/Graftty/Views/WorktreeRow.swift` immediately above the `@ViewBuilder` for `branchLabel` (line 325):

```swift
/// @spec LAYOUT-2.26
/// When the main-checkout worktree's current branch differs from
/// the repository's resolved default branch, the sidebar row shall
/// render the current branch as a dimmed secondary caption beneath
/// the primary label.
```

Then re-run:

Run: `uv run scripts/generate-specs.py`
Expected: success.

- [ ] **Step 2: Verify against CI's check mode**

Run: `uv run scripts/generate-specs.py --check`
Expected: exit 0 (SPECS.md is current).

- [ ] **Step 3: Commit**

```bash
git add SPECS.md Sources/Graftty/Views/WorktreeRow.swift
git commit -m "docs(specs): LAYOUT-2.25..2.29 — stable main-checkout label"
```

---

## Self-Review

**Spec coverage:**
- LAYOUT-2.25 (primary label = default branch) → Task 5 test `mainCheckoutLabelUsesResolvedDefaultBranch`.
- LAYOUT-2.26 (secondary caption when divergent) → Task 6 `@spec` doc comment on `branchLabel`; structural behavior already implemented by the existing `WorktreeRow.swift:361` dedup once Task 5 lands.
- LAYOUT-2.27 (always-house icon) → Task 4 test `mainCheckoutAlwaysUsesHouseSymbolEvenWithPR`.
- LAYOUT-2.28 (resolution chain) → Task 5 test `mainCheckoutLabelFallsBackToMain` plus Task 1 (snapshot field) plus Task 2 (hint field). The full chain is exercised at the call sites in Task 5.
- LAYOUT-2.29 (snapshot.defaultBranch from symbolic-ref) → Task 1 tests + Task 1 `@spec` doc comment.

**Placeholder scan:**
- No "TBD" / "TODO" / "implement later" strings.
- Task 5 references "the actual struct shape you find" for `PaneMoveMenuContext` — engineer is told to read the file and preserve existing fields. Acceptable: the struct's shape is in the repo, not invented here.
- Task 6 instructs running `--check`. No vague "verify it works."

**Type consistency:**
- `defaultBranch: String?` — same name in `RemoteBranchSnapshot`, `SidebarWorktreeLabel.text`, `SidebarWorktreeLabel.texts`, `PaneMoveMenuContext.defaultBranchesByRepoPath` lookup helper.
- `defaultBranchHint: String?` — same name on `RepoEntry`, in callers' fallback chain.
- `parseDefaultBranch` / `parseDefaultBranchForTesting` — paired naming matches existing `parseUpstreams` / `parseUpstreamsForTesting` convention.
- `WorktreeRowIcon.symbolName(isMainCheckout:hasPR:)` — same signature, just reordered conditions; callers unaffected.
