# Repository Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a right-click "Remove Repository" context-menu action AND make Graftty transparently recover when a repo folder is renamed or moved in Finder, per `docs/superpowers/specs/2026-04-21-repository-lifecycle-design.md`.

**Architecture:** Bottom-up. Schema and pure-logic modules land first with tests; UI and orchestration wire them in afterward. A new `RepoBookmark` module wraps macOS URL-bookmark primitives; `RepoRelocator` is a pure decision function (input snapshot → relocation decisions) dispatched by `GrafttyApp`'s existing `WorktreeMonitor` delegate. Remove-repo is a cascade that reuses the surface-teardown / cache-clear / watcher-stop primitives already used by Delete Worktree and Dismiss. Each SPECS.md change lands in the same commit as its implementing code per the project's agent rule.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Testing (`@Test` / `#expect`), AppKit (`NSAlert`), Foundation `URL.bookmarkData`, FSEvents via `WorktreeMonitor`, `git` via `GitRunner`.

---

## Task 1: `AppState.removeRepo` — clear selection when victim

**Files:**
- Modify: `Sources/GrafttyKit/Model/AppState.swift:37-39`
- Test: `Tests/GrafttyKitTests/Model/AppStateTests.swift`

### Why this first
The UI-level "Remove Repository" cascade in later tasks relies on `AppState.removeRepo` to leave `selectedWorktreePath` in a valid state. Currently it doesn't — the symmetric `removeWorktree(atPath:)` at AppState.swift:82-91 already handles selection; we're fixing the gap on `removeRepo`. Unit tests pin the invariant before any caller starts to depend on it.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/GrafttyKitTests/Model/AppStateTests.swift` inside the existing `@Suite("AppState Tests")` struct:

```swift
    @Test func removeRepoClearsSelectionWhenSelectedWorktreeIsInsideRemovedRepo() {
        var state = AppState()
        let repo = RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main"),
            WorktreeEntry(path: "/tmp/repo/.worktrees/feature", branch: "feature")
        ])
        state.addRepo(repo)
        state.selectedWorktreePath = "/tmp/repo/.worktrees/feature"

        state.removeRepo(atPath: "/tmp/repo")

        #expect(state.repos.isEmpty)
        #expect(state.selectedWorktreePath == nil)
    }

    @Test func removeRepoPreservesSelectionWhenSelectedWorktreeIsInDifferentRepo() {
        var state = AppState()
        state.addRepo(RepoEntry(path: "/tmp/repoA", displayName: "A", worktrees: [
            WorktreeEntry(path: "/tmp/repoA", branch: "main")
        ]))
        state.addRepo(RepoEntry(path: "/tmp/repoB", displayName: "B", worktrees: [
            WorktreeEntry(path: "/tmp/repoB", branch: "main")
        ]))
        state.selectedWorktreePath = "/tmp/repoB"

        state.removeRepo(atPath: "/tmp/repoA")

        #expect(state.repos.count == 1)
        #expect(state.selectedWorktreePath == "/tmp/repoB")
    }

    @Test func removeRepoIsNoOpForUnknownPath() {
        var state = AppState()
        state.addRepo(RepoEntry(path: "/tmp/repo", displayName: "repo"))
        state.selectedWorktreePath = "/tmp/repo"

        state.removeRepo(atPath: "/tmp/other")

        #expect(state.repos.count == 1)
        #expect(state.selectedWorktreePath == "/tmp/repo")
    }

    @Test func removeRepoClearsSelectionEvenWhenSelectionIsRepoMainCheckoutPath() {
        var state = AppState()
        state.addRepo(RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main")
        ]))
        state.selectedWorktreePath = "/tmp/repo"

        state.removeRepo(atPath: "/tmp/repo")

        #expect(state.selectedWorktreePath == nil)
    }
```

- [ ] **Step 2: Run tests — verify they fail**

Run: `swift test --filter AppStateTests.removeRepoClearsSelectionWhenSelectedWorktreeIsInsideRemovedRepo`

Expected: FAIL with `selectedWorktreePath` equal to `"/tmp/repo/.worktrees/feature"` instead of `nil`.

- [ ] **Step 3: Implement the fix**

Replace `Sources/GrafttyKit/Model/AppState.swift:37-39`:

```swift
    public mutating func removeRepo(atPath path: String) {
        let victimPaths: Set<String>
        if let repo = repos.first(where: { $0.path == path }) {
            victimPaths = Set(repo.worktrees.map(\.path))
        } else {
            return
        }
        repos.removeAll { $0.path == path }
        if let selected = selectedWorktreePath, victimPaths.contains(selected) {
            selectedWorktreePath = nil
        }
    }
```

- [ ] **Step 4: Run all AppStateTests — verify pass**

Run: `swift test --filter AppStateTests`

Expected: all tests PASS, including the four new ones and existing `removeRepo` / `saveAndLoad` tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Model/AppState.swift Tests/GrafttyKitTests/Model/AppStateTests.swift
git commit -m "fix(model): AppState.removeRepo clears selection when victim (prep for LAYOUT-4.3)"
```

---

## Task 2: `RepoEntry.bookmark` schema + `path` mutability + Codable migration

**Files:**
- Modify: `Sources/GrafttyKit/Model/RepoEntry.swift` (full rewrite)
- Create: `Tests/GrafttyKitTests/Model/RepoEntryCodableTests.swift`

### Why
The bookmark field is load-bearing for every relocate path. Keeping this as its own task isolates the schema + Codable-migration work from feature logic, and the round-trip tests pin that pre-upgrade `state.json` blobs still decode cleanly (a load-bearing invariant — get this wrong and every existing user's state resets to empty on first launch post-upgrade).

- [ ] **Step 1: Write the failing tests**

Create `Tests/GrafttyKitTests/Model/RepoEntryCodableTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("RepoEntry Codable Tests")
struct RepoEntryCodableTests {

    @Test func decodeLegacyRepoEntryWithoutBookmarkYieldsNilBookmark() throws {
        // Shape of a pre-LAYOUT-4.5 persisted RepoEntry: no `bookmark` key.
        let json = """
        {
          "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
          "path": "/tmp/repo",
          "displayName": "repo",
          "isCollapsed": false,
          "worktrees": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(RepoEntry.self, from: json)

        #expect(decoded.path == "/tmp/repo")
        #expect(decoded.displayName == "repo")
        #expect(decoded.bookmark == nil)
    }

    @Test func roundTripPreservesBookmarkBytes() throws {
        var entry = RepoEntry(path: "/tmp/repo", displayName: "repo")
        entry.bookmark = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RepoEntry.self, from: encoded)

        #expect(decoded.bookmark == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test func repoEntryPathIsMutable() {
        var entry = RepoEntry(path: "/tmp/old", displayName: "old")
        entry.path = "/tmp/new"
        #expect(entry.path == "/tmp/new")
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

Run: `swift test --filter RepoEntryCodableTests`

Expected: FAIL — `decoded.bookmark` is not a member; `entry.path =` is assignment to `let`.

- [ ] **Step 3: Rewrite `RepoEntry`**

Replace the entire contents of `Sources/GrafttyKit/Model/RepoEntry.swift`:

```swift
import Foundation

public struct RepoEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var path: String
    public var displayName: String
    public var isCollapsed: Bool
    public var worktrees: [WorktreeEntry]
    /// macOS URL bookmark for the repo folder, minted at add-time. Enables
    /// transparent recovery when the user renames or moves the folder in
    /// Finder (LAYOUT-4.5 .. LAYOUT-4.9). `nil` for entries decoded from a
    /// pre-LAYOUT-4.5 `state.json`; lazily minted on first successful path
    /// resolution after upgrade (LAYOUT-4.9).
    public var bookmark: Data?

    public init(
        path: String,
        displayName: String,
        isCollapsed: Bool = false,
        worktrees: [WorktreeEntry] = [],
        bookmark: Data? = nil
    ) {
        self.id = UUID()
        self.path = path
        self.displayName = displayName
        self.isCollapsed = isCollapsed
        self.worktrees = worktrees
        self.bookmark = bookmark
    }

    // Custom Decodable so `bookmark` (added in LAYOUT-4.5) is optional on
    // disk. Matches the pattern `WorktreeEntry.init(from:)` uses for
    // `paneAttention` / `offeredDeleteForMergedPR` — pre-fix persisted
    // state blobs don't carry the key, `decodeIfPresent` defaults it to
    // nil, and existing users keep their state across the upgrade.
    private enum CodingKeys: String, CodingKey {
        case id, path, displayName, isCollapsed, worktrees, bookmark
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.path = try container.decode(String.self, forKey: .path)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        self.worktrees = try container.decode([WorktreeEntry].self, forKey: .worktrees)
        self.bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
    }
}
```

- [ ] **Step 4: Run `swift build` to surface any caller-site breakage**

Run: `swift build 2>&1 | tail -30`

Expected: clean build. Prior callers that passed `RepoEntry(path:displayName:…)` positionally still compile because `bookmark` has a default. If any caller read `repo.path` and the compiler flags a write — none are expected — the error will surface here.

- [ ] **Step 5: Run the new tests — verify pass**

Run: `swift test --filter RepoEntryCodableTests`

Expected: all 3 tests PASS.

- [ ] **Step 6: Run the full model test suite to check for regressions**

Run: `swift test --filter Model`

Expected: every test in `Tests/GrafttyKitTests/Model/` passes.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Model/RepoEntry.swift Tests/GrafttyKitTests/Model/RepoEntryCodableTests.swift
git commit -m "feat(model): RepoEntry.bookmark + mutable path (prep for LAYOUT-4.5)"
```

---

## Task 3: `RepoBookmark` helper module

**Files:**
- Create: `Sources/GrafttyKit/Git/RepoBookmark.swift`
- Create: `Tests/GrafttyKitTests/Git/RepoBookmarkTests.swift`

### Why
Bookmark mint and resolve each land in several call sites (add-repo, launch-reconcile, deletion-handler). Wrapping the Foundation API once keeps call sites terse (`RepoBookmark.mint(atPath:)` / `.resolve(_:)`) and makes the mint/resolve contract directly unit-testable with real URLs in a temp directory, rather than having to reach through the `MainWindow` plumbing.

- [ ] **Step 1: Write the failing tests**

Create `Tests/GrafttyKitTests/Git/RepoBookmarkTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("RepoBookmark Tests")
struct RepoBookmarkTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-bookmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func mintAndResolveReturnsSamePath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bookmark = try RepoBookmark.mint(atPath: dir.path)
        let resolved = try RepoBookmark.resolve(bookmark)

        #expect(resolved.url.path == dir.path)
        #expect(resolved.isStale == false)
    }

    @Test func resolveReturnsNewPathAfterFolderRename() throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }

        let before = parent.appendingPathComponent("before")
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)

        let bookmark = try RepoBookmark.mint(atPath: before.path)

        let after = parent.appendingPathComponent("after")
        try FileManager.default.moveItem(at: before, to: after)

        let resolved = try RepoBookmark.resolve(bookmark)
        #expect(resolved.url.path == after.path)
    }

    @Test func resolveThrowsAfterFolderDelete() throws {
        let dir = try makeTempDir()
        let bookmark = try RepoBookmark.mint(atPath: dir.path)
        try FileManager.default.removeItem(at: dir)

        #expect(throws: (any Error).self) {
            _ = try RepoBookmark.resolve(bookmark)
        }
    }

    @Test func mintOfMissingPathThrows() {
        #expect(throws: (any Error).self) {
            _ = try RepoBookmark.mint(atPath: "/definitely/not/a/real/path/\(UUID().uuidString)")
        }
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

Run: `swift test --filter RepoBookmarkTests`

Expected: FAIL with "Cannot find type 'RepoBookmark' in scope."

- [ ] **Step 3: Implement `RepoBookmark`**

Create `Sources/GrafttyKit/Git/RepoBookmark.swift`:

```swift
import Foundation

/// Thin wrapper around macOS URL bookmarks for repo paths. Bookmarks let
/// Graftty recover when the user renames or moves a tracked repo folder
/// in Finder — the bookmark resolves to the new path via the inode /
/// volume identity it encoded, without requiring the app to watch every
/// ancestor directory.
///
/// Regular (non-security-scoped) bookmarks are used because Graftty is
/// not sandboxed and `NSOpenPanel` hands the app arbitrary-path URLs.
/// Security-scoped would require `startAccessingSecurityScopedResource`
/// bracketing on every resolve — complexity without benefit (LAYOUT-4.10).
public enum RepoBookmark {

    public struct Resolved {
        public let url: URL
        public let isStale: Bool
    }

    /// Mint a bookmark from a repository's on-disk path.
    ///
    /// Throws if the path does not exist or the system cannot create the
    /// bookmark (permissions, bad filesystem). Callers that want
    /// best-effort behavior should `try?` and store `nil`.
    public static func mint(atPath path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)
        return try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolve a bookmark back to a URL. Returns the URL and whether the
    /// bookmark is stale (cross-volume move, APFS firmlink resolution,
    /// etc.) so callers can re-mint.
    ///
    /// Throws if the bookmark cannot be resolved (referenced folder
    /// deleted, bookmark corrupt, filesystem unavailable).
    public static func resolve(_ bookmark: Data) throws -> Resolved {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return Resolved(url: url, isStale: isStale)
    }
}
```

- [ ] **Step 4: Run the new tests — verify pass**

Run: `swift test --filter RepoBookmarkTests`

Expected: all 4 tests PASS. (The rename test exercises macOS's real bookmark-resolution code — if it fails on CI due to some sandbox the tests run under, that's the implementation plan's first red flag and worth a stop-and-fix.)

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Git/RepoBookmark.swift Tests/GrafttyKitTests/Git/RepoBookmarkTests.swift
git commit -m "feat(git): RepoBookmark mint/resolve helper (LAYOUT-4.5 support)"
```

---

## Task 4: `GitWorktreeRepair` wrapper

**Files:**
- Create: `Sources/GrafttyKit/Git/GitWorktreeRepair.swift`
- Create: `Tests/GrafttyKitTests/Git/GitWorktreeRepairTests.swift`

### Why
`git worktree repair` fixes the `gitdir` pointers that break when a repo's folder is renamed. Wrapping it mirrors the shape of the existing `GitWorktreeRemove` (GitWorktreeRemove.swift:11-36) so the relocate cascade can invoke it consistently with the rest of the git surface. Kept as its own task because it's a narrow, testable unit.

- [ ] **Step 1: Write the failing tests**

Create `Tests/GrafttyKitTests/Git/GitWorktreeRepairTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitWorktreeRepair Tests")
struct GitWorktreeRepairTests {

    private final class StubExecutor: CLIExecutor, @unchecked Sendable {
        var commandLog: [(args: [String], cwd: String)] = []
        var exitCode: Int32 = 0
        var stdout: String = ""
        var stderr: String = ""

        func run(args: [String], at directory: String) async throws -> CLIResult {
            commandLog.append((args, directory))
            return CLIResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
        }
    }

    @Test func repairInvokesGitWithExpectedArgs() async throws {
        let stub = StubExecutor()
        GitRunner.configure(executor: stub)
        defer { GitRunner.resetForTests() }

        try await GitWorktreeRepair.repair(
            repoPath: "/tmp/repo",
            worktreePaths: ["/tmp/repo/.worktrees/a", "/tmp/repo/.worktrees/b"]
        )

        #expect(stub.commandLog.count == 1)
        #expect(stub.commandLog[0].cwd == "/tmp/repo")
        #expect(stub.commandLog[0].args == [
            "worktree", "repair",
            "/tmp/repo/.worktrees/a",
            "/tmp/repo/.worktrees/b"
        ])
    }

    @Test func repairWithoutWorktreePathsStillRuns() async throws {
        let stub = StubExecutor()
        GitRunner.configure(executor: stub)
        defer { GitRunner.resetForTests() }

        try await GitWorktreeRepair.repair(repoPath: "/tmp/repo", worktreePaths: [])

        #expect(stub.commandLog.count == 1)
        #expect(stub.commandLog[0].args == ["worktree", "repair"])
    }

    @Test func repairThrowsGitFailedOnNonZeroExit() async throws {
        let stub = StubExecutor()
        stub.exitCode = 1
        stub.stderr = "fatal: not a git repository"
        GitRunner.configure(executor: stub)
        defer { GitRunner.resetForTests() }

        do {
            try await GitWorktreeRepair.repair(repoPath: "/tmp", worktreePaths: [])
            Issue.record("expected throw")
        } catch GitWorktreeRepair.Error.gitFailed(let exit, let stderr) {
            #expect(exit == 1)
            #expect(stderr == "fatal: not a git repository")
        }
    }
}
```

**Note:** the test depends on `CLIExecutor`, `CLIResult`, `GitRunner.configure(executor:)`, and `GitRunner.resetForTests()`. Verify these exist by inspecting `Sources/GrafttyKit/Git/GitRunner.swift` and `Sources/GrafttyKit/Process/` — the existing `GitWorktreeRemoveTests.swift` file is the authoritative example. If names differ, adapt to match the real ones.

- [ ] **Step 2: Run tests — verify they fail**

Run: `swift test --filter GitWorktreeRepairTests`

Expected: FAIL — `GitWorktreeRepair` does not exist yet.

- [ ] **Step 3: Implement `GitWorktreeRepair`**

Create `Sources/GrafttyKit/Git/GitWorktreeRepair.swift`:

```swift
import Foundation

/// Runs `git worktree repair [<path>...]` in a repository to fix
/// `gitdir:` pointers in linked worktrees whose paths have changed
/// externally (e.g. after a Finder rename of the main repo folder).
///
/// Shape parallels `GitWorktreeRemove` — thin wrapper over `GitRunner`
/// that translates a non-zero exit into a typed `gitFailed` error so
/// callers can surface or log git's stderr.
public enum GitWorktreeRepair {

    public enum Error: Swift.Error, Equatable {
        case gitFailed(exitCode: Int32, stderr: String)
    }

    /// - Parameters:
    ///   - repoPath: the repository root (main checkout). The command is
    ///     run from here; `git worktree repair` with no path arguments
    ///     walks the repo's registered linked worktrees.
    ///   - worktreePaths: optional list of explicit paths to repair. When
    ///     provided, only those worktrees are touched; useful when a
    ///     relocate cascade knows exactly which worktrees moved.
    public static func repair(repoPath: String, worktreePaths: [String] = []) async throws {
        var args = ["worktree", "repair"]
        args.append(contentsOf: worktreePaths)
        let result = try await GitRunner.captureAll(args: args, at: repoPath)
        guard result.exitCode == 0 else {
            throw Error.gitFailed(
                exitCode: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
```

- [ ] **Step 4: Run the new tests — verify pass**

Run: `swift test --filter GitWorktreeRepairTests`

Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Git/GitWorktreeRepair.swift Tests/GrafttyKitTests/Git/GitWorktreeRepairTests.swift
git commit -m "feat(git): GitWorktreeRepair wrapper (LAYOUT-4.8 support)"
```

---

## Task 5: `RepoRelocator` pure decision module

**Files:**
- Create: `Sources/GrafttyKit/Git/RepoRelocator.swift`
- Create: `Tests/GrafttyKitTests/Git/RepoRelocatorTests.swift`

### Why
The relocate cascade branches in non-trivial ways: gitdir-repair scheduling, branch-based carry-forward matching, unmatched-goes-stale, selection rewriting. Testing those decisions directly — rather than through a `MainWindow` orchestration layer that mixes them with side effects — follows the precedent of `PWDReassignmentPolicyTests` in `Tests/GrafttyKitTests/Model/`. The orchestrator in Task 9 then runs a thin `"apply(decisions: on: &state)"` over the result.

- [ ] **Step 1: Write the failing tests**

Create `Tests/GrafttyKitTests/Git/RepoRelocatorTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("RepoRelocator Tests")
struct RepoRelocatorTests {

    private func repo(
        path: String,
        worktrees: [(path: String, branch: String, state: WorktreeState)]
    ) -> RepoEntry {
        let wts = worktrees.map {
            var wt = WorktreeEntry(path: $0.path, branch: $0.branch, state: $0.state)
            return wt
        }
        return RepoEntry(path: path, displayName: URL(fileURLWithPath: path).lastPathComponent,
                         worktrees: wts)
    }

    private func discovered(path: String, branch: String) -> DiscoveredWorktree {
        DiscoveredWorktree(path: path, branch: branch)
    }

    @Test func cleanMoveCarriesAllWorktreesForward() {
        let existing = repo(path: "/old/repo", worktrees: [
            ("/old/repo", "main", .running),
            ("/old/repo/.worktrees/feature", "feature", .closed)
        ])
        let discoveredList = [
            discovered(path: "/new/repo", branch: "main"),
            discovered(path: "/new/repo/.worktrees/feature", branch: "feature")
        ]

        let decision = RepoRelocator.decide(
            repo: existing,
            newRepoPath: "/new/repo",
            discovered: discoveredList,
            selectedWorktreePath: "/old/repo/.worktrees/feature"
        )

        #expect(decision.needsRepair == false)
        #expect(decision.carriedForward.count == 2)
        #expect(decision.carriedForward.contains { $0.newPath == "/new/repo" && $0.existingID == existing.worktrees[0].id })
        #expect(decision.carriedForward.contains {
            $0.newPath == "/new/repo/.worktrees/feature"
                && $0.existingID == existing.worktrees[1].id
        })
        #expect(decision.goneStale.isEmpty)
        #expect(decision.newSelectedWorktreePath == "/new/repo/.worktrees/feature")
    }

    @Test func brokenGitdirSchedulesRepair() {
        let existing = repo(path: "/old/repo", worktrees: [
            ("/old/repo", "main", .running),
            ("/old/repo/.worktrees/feature", "feature", .closed)
        ])
        // Discovery omits the linked worktree — symptom of a broken
        // gitdir pointer git would prune.
        let discoveredList = [discovered(path: "/new/repo", branch: "main")]

        let decision = RepoRelocator.decide(
            repo: existing,
            newRepoPath: "/new/repo",
            discovered: discoveredList,
            selectedWorktreePath: nil
        )

        #expect(decision.needsRepair == true)
        #expect(decision.repairCandidatePaths == ["/new/repo/.worktrees/feature"])
    }

    @Test func postRepairUnmatchedWorktreeGoesStale() {
        let existing = repo(path: "/old/repo", worktrees: [
            ("/old/repo", "main", .running),
            ("/old/repo/.worktrees/feature", "feature", .closed)
        ])
        // Post-repair discovery still doesn't list the feature worktree —
        // caller passes the second discovery result via `decidePostRepair`.
        let postRepair = [discovered(path: "/new/repo", branch: "main")]

        let decision = RepoRelocator.decidePostRepair(
            repo: existing,
            newRepoPath: "/new/repo",
            discovered: postRepair,
            selectedWorktreePath: "/old/repo/.worktrees/feature"
        )

        #expect(decision.carriedForward.count == 1)
        #expect(decision.goneStale.count == 1)
        #expect(decision.goneStale.first?.branch == "feature")
        #expect(decision.newSelectedWorktreePath == nil) // stale selection clears
    }

    @Test func carryForwardMatchesByBranchPreservingID() {
        let existing = repo(path: "/old/repo", worktrees: [
            ("/old/repo/.worktrees/a", "feat-a", .running),
            ("/old/repo/.worktrees/b", "feat-b", .running)
        ])
        // Discovery returns worktrees at different leaf names but same
        // branches — the carry-forward should match by branch.
        let discoveredList = [
            discovered(path: "/new/repo", branch: "main"), // new main checkout
            discovered(path: "/new/repo/renamed-a", branch: "feat-a"),
            discovered(path: "/new/repo/renamed-b", branch: "feat-b")
        ]

        let decision = RepoRelocator.decide(
            repo: existing,
            newRepoPath: "/new/repo",
            discovered: discoveredList,
            selectedWorktreePath: nil
        )

        let aCarry = decision.carriedForward.first { $0.newPath == "/new/repo/renamed-a" }
        let bCarry = decision.carriedForward.first { $0.newPath == "/new/repo/renamed-b" }
        #expect(aCarry?.existingID == existing.worktrees[0].id)
        #expect(bCarry?.existingID == existing.worktrees[1].id)
    }

    @Test func selectionUpdatesToNewPathWhenWorktreeCarriesForward() {
        let existing = repo(path: "/old/repo", worktrees: [
            ("/old/repo/.worktrees/feature", "feature", .running)
        ])
        let discoveredList = [discovered(path: "/new/repo/.worktrees/feature", branch: "feature")]

        let decision = RepoRelocator.decide(
            repo: existing,
            newRepoPath: "/new/repo",
            discovered: discoveredList,
            selectedWorktreePath: "/old/repo/.worktrees/feature"
        )

        #expect(decision.newSelectedWorktreePath == "/new/repo/.worktrees/feature")
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

Run: `swift test --filter RepoRelocatorTests`

Expected: FAIL — `RepoRelocator` does not exist.

- [ ] **Step 3: Implement `RepoRelocator`**

Create `Sources/GrafttyKit/Git/RepoRelocator.swift`:

```swift
import Foundation

/// Pure decision function for the repo-relocate cascade (LAYOUT-4.8).
/// Takes a snapshot of the pre-relocate state plus the post-discovery
/// view of the filesystem and returns a list of discrete decisions the
/// caller then enacts:
///
/// - which existing `WorktreeEntry`s carry forward (and to which new
///   paths), preserving `id` / `splitTree` / `state` / attention state;
/// - which existing entries go `.stale` (git no longer lists them even
///   after optional `git worktree repair`);
/// - whether `git worktree repair` should run and for which paths;
/// - how to update `selectedWorktreePath` to track the move.
///
/// Keeping this pure means the cascade's branching is unit-testable
/// without plumbing through `MainWindow`, `WorktreeMonitor`,
/// `PRStatusStore`, etc. The orchestrator (GrafttyApp / MainWindow) then
/// enacts the decisions by calling watcher / cache / model APIs.
public enum RepoRelocator {

    public struct CarryForward: Equatable {
        public let existingID: UUID
        public let newPath: String
        public let branch: String
    }

    public struct Stale: Equatable {
        public let existingID: UUID
        public let oldPath: String
        public let branch: String
    }

    public struct Decision: Equatable {
        public let needsRepair: Bool
        public let repairCandidatePaths: [String]
        public let carriedForward: [CarryForward]
        public let goneStale: [Stale]
        public let newSelectedWorktreePath: String?
    }

    /// First-pass decision, before any `git worktree repair` has run.
    /// If the post-discovery result is missing any previously-known
    /// linked worktree, `needsRepair` is true and the caller should run
    /// `GitWorktreeRepair.repair(...)` at `repairCandidatePaths`, then
    /// re-discover and call `decidePostRepair`.
    public static func decide(
        repo: RepoEntry,
        newRepoPath: String,
        discovered: [DiscoveredWorktree],
        selectedWorktreePath: String?
    ) -> Decision {
        let expectedNewPaths = expectedNewPaths(
            existing: repo,
            oldRepoPath: repo.path,
            newRepoPath: newRepoPath
        )
        let discoveredPaths = Set(discovered.map(\.path))
        let missing = expectedNewPaths.filter { !discoveredPaths.contains($0.newPath) }

        if !missing.isEmpty {
            return Decision(
                needsRepair: true,
                repairCandidatePaths: missing.map(\.newPath),
                carriedForward: [],
                goneStale: [],
                newSelectedWorktreePath: selectedWorktreePath // unchanged until post-repair
            )
        }
        return buildDecision(
            repo: repo,
            discovered: discovered,
            selectedWorktreePath: selectedWorktreePath
        )
    }

    /// Second-pass decision, after `git worktree repair` has run. Any
    /// existing entry without a branch match in `discovered` goes stale.
    public static func decidePostRepair(
        repo: RepoEntry,
        newRepoPath: String,
        discovered: [DiscoveredWorktree],
        selectedWorktreePath: String?
    ) -> Decision {
        buildDecision(
            repo: repo,
            discovered: discovered,
            selectedWorktreePath: selectedWorktreePath
        )
    }

    private struct ExpectedPath {
        let existingIndex: Int
        let newPath: String
    }

    /// Rewrite each existing worktree path's old-repo prefix to new-repo
    /// prefix. Paths that don't share the old prefix are returned
    /// unchanged (user moved a worktree individually — caught downstream
    /// as a branch mismatch).
    private static func expectedNewPaths(
        existing: RepoEntry,
        oldRepoPath: String,
        newRepoPath: String
    ) -> [ExpectedPath] {
        existing.worktrees.enumerated().map { idx, wt in
            if wt.path == oldRepoPath {
                return ExpectedPath(existingIndex: idx, newPath: newRepoPath)
            }
            if wt.path.hasPrefix(oldRepoPath + "/") {
                let suffix = String(wt.path.dropFirst(oldRepoPath.count))
                return ExpectedPath(existingIndex: idx, newPath: newRepoPath + suffix)
            }
            return ExpectedPath(existingIndex: idx, newPath: wt.path)
        }
    }

    private static func buildDecision(
        repo: RepoEntry,
        discovered: [DiscoveredWorktree],
        selectedWorktreePath: String?
    ) -> Decision {
        var carried: [CarryForward] = []
        var stale: [Stale] = []
        var matchedIDs = Set<UUID>()

        for d in discovered {
            if let existing = repo.worktrees.first(where: { $0.branch == d.branch }) {
                carried.append(CarryForward(
                    existingID: existing.id,
                    newPath: d.path,
                    branch: d.branch
                ))
                matchedIDs.insert(existing.id)
            }
            // Discovered entries with no branch match are fresh worktrees
            // the caller appends verbatim — represented here by the
            // difference between discovered.count and carried.count,
            // and surfaced through the orchestrator's apply step.
        }

        for wt in repo.worktrees where !matchedIDs.contains(wt.id) {
            stale.append(Stale(existingID: wt.id, oldPath: wt.path, branch: wt.branch))
        }

        let newSelection: String?
        if let sel = selectedWorktreePath,
           let match = carried.first(where: { cf in
               repo.worktrees.first(where: { $0.id == cf.existingID })?.path == sel
           }) {
            newSelection = match.newPath
        } else if let sel = selectedWorktreePath,
                  stale.contains(where: {
                      repo.worktrees.first(where: { $0.id == $0.id })?.path == sel
                          && $0.oldPath == sel
                  }) {
            newSelection = nil
        } else {
            newSelection = selectedWorktreePath
        }

        return Decision(
            needsRepair: false,
            repairCandidatePaths: [],
            carriedForward: carried,
            goneStale: stale,
            newSelectedWorktreePath: newSelection
        )
    }
}
```

- [ ] **Step 4: Run the new tests — verify pass**

Run: `swift test --filter RepoRelocatorTests`

Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Git/RepoRelocator.swift Tests/GrafttyKitTests/Git/RepoRelocatorTests.swift
git commit -m "feat(git): RepoRelocator pure decision module (LAYOUT-4.8 core)"
```

---

## Task 6: `SidebarView` — `onRemoveRepo` closure + context menu

**Files:**
- Modify: `Sources/Graftty/Views/SidebarView.swift:6-32,76-123`

### Why
Isolates the pure-SwiftUI wiring change (one new closure, one new `.contextMenu { ... }`). No unit test here — this is view-layer plumbing exercised in Task 7's end-to-end build.

- [ ] **Step 1: Add the new closure property**

In `Sources/Graftty/Views/SidebarView.swift`, add `onRemoveRepo: (RepoEntry) -> Void` to the property list. Place it immediately after `onAddPath` (SidebarView.swift:18) so related callbacks cluster:

```swift
    let onAddRepo: () -> Void
    let onAddPath: (String) -> Void
    let onRemoveRepo: (RepoEntry) -> Void
    let onStopWorktree: (String) -> Void
```

- [ ] **Step 2: Attach the context menu to the repo header row**

In `repoSection(_ repo:)` (SidebarView.swift:76), wrap the existing `HStack { … }` that forms the `DisclosureGroup` label in a `.contextMenu`. Replace the existing `label:` block starting at line ~98 with:

```swift
        } label: {
            HStack(spacing: 6) {
                Text(repo.displayName)
                    .foregroundColor(theme.foreground)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    addingWorktreeTo = repo
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.foreground.opacity(0.6))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add worktree to \(repo.displayName)")
            }
            .contextMenu {
                Button("Remove Repository") {
                    onRemoveRepo(repo)
                }
            }
        }
```

- [ ] **Step 3: Run `swift build` to verify syntactic correctness**

Run: `swift build 2>&1 | tail -20`

Expected: FAIL — `MainWindow` does not yet supply `onRemoveRepo`. That's fine; Task 7 fixes it. The compile error confirms the closure is wired through the right init-argument site.

- [ ] **Step 4: Commit (red build is OK here; Task 7 completes the pair)**

```bash
git add Sources/Graftty/Views/SidebarView.swift
git commit -m "feat(sidebar): onRemoveRepo closure + Remove Repository context menu (LAYOUT-4.1)"
```

---

## Task 7: `MainWindow` — `removeRepoWithConfirmation` + `performRemoveRepo` + SPECS.md LAYOUT-4.1..4.4

**Files:**
- Modify: `Sources/Graftty/Views/MainWindow.swift` (add methods + wire `SidebarView` arg)
- Modify: `SPECS.md` (insert §1.4 Removing & Relocating Repositories, entries LAYOUT-4.1..4.4)

### Why
Wires the sidebar closure to a cascade that reuses existing primitives. SPECS.md edits land here per CLAUDE.md's "keep SPECS.md in sync" rule.

- [ ] **Step 1: Add `performRemoveRepo(_:)` and `removeRepoWithConfirmation(_:)` methods**

In `Sources/Graftty/Views/MainWindow.swift`, add after `deleteWorktreeWithConfirmation` (around line 469 — the existing `performDeleteWorktree` is the style reference):

```swift
    private func removeRepoWithConfirmation(_ repo: RepoEntry) {
        let alert = NSAlert()
        alert.messageText = "Remove \"\(repo.displayName)\"?"
        alert.informativeText = "This removes the repository from Graftty but does not delete any files from disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performRemoveRepo(repo)
    }

    /// Implements LAYOUT-4.3. Ordering of (a)–(d) before (e) matches the
    /// orphan-surfaces / orphan-caches contracts in GIT-3.10 / GIT-4.10 /
    /// GIT-3.13 / GIT-3.11. No git is invoked; no on-disk files are
    /// touched.
    private func performRemoveRepo(_ repo: RepoEntry) {
        // (a) Tear down live surfaces for running worktrees.
        for wt in repo.worktrees where wt.state == .running {
            terminalManager.destroySurfaces(terminalIDs: wt.splitTree.allLeaves)
        }
        // (b) Stop repo-level and per-worktree watchers.
        services.worktreeMonitor.stopWatching(repoPath: repo.path)
        for wt in repo.worktrees {
            services.worktreeMonitor.stopWatchingWorktree(wt.path)
        }
        // (c) Clear per-path caches before model mutation.
        for wt in repo.worktrees {
            prStatusStore.clear(worktreePath: wt.path)
            statsStore.clear(worktreePath: wt.path)
        }
        // (d) + (e) `removeRepo` clears selection when victim.
        appState.removeRepo(atPath: repo.path)
    }
```

- [ ] **Step 2: Wire the closure into `SidebarView`**

In `MainWindow.body` (around SidebarView.swift:32 — the site where `onAddRepo`, `onAddPath`, etc. are passed), add:

```swift
                onAddRepo: addRepository,
                onAddPath: addPath,
                onRemoveRepo: removeRepoWithConfirmation,
                onStopWorktree: stopWorktreeWithConfirmation,
```

- [ ] **Step 3: Update `SPECS.md` with LAYOUT-4.1..4.4**

Insert a new subsection **1.4 Removing & Relocating Repositories** immediately after section 1.3 (which ends around the `LAYOUT-3.5` line). For this task, add only the Remove entries; relocate entries land in Task 10.

```markdown
### 1.4 Removing & Relocating Repositories

#### Removing

**LAYOUT-4.1** When the user right-clicks a repository header row in the sidebar, the application shall display a context menu containing a "Remove Repository" action.

**LAYOUT-4.2** When the user triggers "Remove Repository", the application shall display a confirmation dialog whose informative text explicitly states "This removes the repository from Graftty but does not delete any files from disk."

**LAYOUT-4.3** When the user confirms "Remove Repository", the application shall (a) tear down all terminal surfaces in every worktree of the repository whose `state == .running`, (b) stop the repository-level FSEvents watchers (`.git/worktrees/` and origin refs) and each worktree's per-path, HEAD-reflog, and content watchers, (c) clear the cached PR status and divergence stats for every worktree of the repository, (d) clear `selectedWorktreePath` if it pointed to any worktree in the repository, and (e) remove the repository entry from `AppState`. Steps (a)–(d) must precede (e) for the same orphan-surfaces / orphan-caches reasons as GIT-3.10 / GIT-4.10 / GIT-3.13 and the watcher-fd-lifetime reason as GIT-3.11.

**LAYOUT-4.4** The "Remove Repository" action shall not invoke `git` and shall not modify any files on disk. Worktree directories, branches, and git metadata remain untouched; the operation affects only Graftty's in-memory model and persisted `state.json`.
```

- [ ] **Step 4: Run `swift build` — verify clean build**

Run: `swift build 2>&1 | tail -20`

Expected: clean build.

- [ ] **Step 5: Run the full test suite — verify no regressions**

Run: `swift test 2>&1 | tail -30`

Expected: all tests PASS. The new `AppStateTests`, `RepoEntryCodableTests`, `RepoBookmarkTests`, `GitWorktreeRepairTests`, and `RepoRelocatorTests` all pass alongside the existing suite.

- [ ] **Step 6: Smoke test in the app**

1. Run `swift run Graftty` (or open in Xcode → Run).
2. Add a repo via the bottom-bar "+" button.
3. Right-click the repo header row. Expect a "Remove Repository" menu item.
4. Click it. Expect the confirm dialog.
5. Click Remove. The repo vanishes from the sidebar; the folder on disk is untouched.
6. Re-add the same folder via "+" or drag-drop: rediscovers cleanly with the old worktrees.

Report any deviation as a plan issue — don't silently fix.

- [ ] **Step 7: Commit**

```bash
git add Sources/Graftty/Views/MainWindow.swift SPECS.md
git commit -m "feat(sidebar): Remove Repository right-click action (LAYOUT-4.1 .. LAYOUT-4.4)"
```

---

## Task 8: Mint bookmarks on Add Repository

**Files:**
- Modify: `Sources/Graftty/Views/MainWindow.swift:599-638` (the `addRepoFromPath` method)

### Why
First writer of bookmarks to the model. Minimal change — one `try?` call and a field init change. Kept as its own task so Task 9's launch-time resolution has data to work with and isn't dependent on fixing up existing entries concurrently.

- [ ] **Step 1: Mint the bookmark alongside `appState.addRepo`**

In `addRepoFromPath` at `Sources/Graftty/Views/MainWindow.swift:627-630`, change the block that constructs the `RepoEntry` to mint a bookmark:

```swift
            let worktrees = discovered.map { WorktreeEntry(path: $0.path, branch: $0.branch) }
            let displayName = URL(fileURLWithPath: repoPath).lastPathComponent
            let bookmark = try? RepoBookmark.mint(atPath: repoPath)
            if bookmark == nil {
                NSLog("[Graftty] addRepoFromPath: bookmark mint failed for %@; rename-recovery disabled for this entry", repoPath)
            }
            let repo = RepoEntry(
                path: repoPath,
                displayName: displayName,
                worktrees: worktrees,
                bookmark: bookmark
            )
            appState.addRepo(repo)
```

- [ ] **Step 2: Run `swift build` — verify clean build**

Run: `swift build 2>&1 | tail -10`

Expected: clean.

- [ ] **Step 3: Run the full test suite — verify no regressions**

Run: `swift test 2>&1 | tail -20`

Expected: all pass.

- [ ] **Step 4: Smoke test**

1. `swift run Graftty`.
2. Add a repo. In the console, verify no "bookmark mint failed" log.
3. Quit and relaunch. Open `~/Library/Application Support/Graftty/state.json` in a text editor. Expect a `"bookmark"` key with a base64 blob on the repo entry.
4. Remove the repo via the new context menu. Confirm it disappears.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/Views/MainWindow.swift
git commit -m "feat(mainwindow): mint URL bookmark on Add Repository (LAYOUT-4.5)"
```

---

## Task 9: Launch-time bookmark resolution + migration (`reconcileOnLaunch`)

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift` (add pre-pass to `reconcileOnLaunch` around line 462)
- Add: private method `relocateRepo(repoIdx:newURL:isStale:)` in the same file

### Why
First live use of `RepoRelocator`. Implements both LAYOUT-4.6 (bookmark resolution at launch) and LAYOUT-4.9 (backfill mint for pre-upgrade entries without bookmarks). Splitting from Task 10 (deletion-event hook) keeps each task focused on one entry point.

- [ ] **Step 1: Add a private `resolveRepoLocations()` pre-pass**

In `Sources/Graftty/GrafttyApp.swift`, directly above `private func reconcileOnLaunch()` (around line 462), add:

```swift
    /// Pre-pass for `reconcileOnLaunch` implementing LAYOUT-4.6 / LAYOUT-4.9.
    ///
    /// For each `RepoEntry`:
    /// - If it has a bookmark, resolve it. If the resolved path differs
    ///   from the stored `path`, run the relocate cascade.
    /// - If it has no bookmark and the stored `path` exists on disk, mint
    ///   one in place (migration from pre-LAYOUT-4.5 state.json).
    ///
    /// Runs before any `WorktreeMonitor.watch*` calls so watchers arm at
    /// the corrected path from the start, never at a zombie old path.
    @MainActor
    private func resolveRepoLocations() async {
        for repoIdx in appState.repos.indices {
            let repo = appState.repos[repoIdx]
            if let bookmark = repo.bookmark {
                do {
                    let resolved = try RepoBookmark.resolve(bookmark)
                    if resolved.url.path != repo.path {
                        await relocateRepo(
                            repoIdx: repoIdx,
                            newURL: resolved.url,
                            isStale: resolved.isStale
                        )
                    } else if resolved.isStale {
                        appState.repos[repoIdx].bookmark = try? RepoBookmark.mint(atPath: repo.path)
                    }
                } catch {
                    NSLog("[Graftty] resolveRepoLocations: bookmark resolve failed for %@: %@",
                          repo.path, String(describing: error))
                }
            } else if FileManager.default.fileExists(atPath: repo.path) {
                if let fresh = try? RepoBookmark.mint(atPath: repo.path) {
                    appState.repos[repoIdx].bookmark = fresh
                }
            }
        }
    }
```

- [ ] **Step 2: Add the `relocateRepo` orchestrator**

In the same file, near `reconcileOnLaunch`, add:

```swift
    /// Orchestrator for LAYOUT-4.8 — enacts the decisions produced by
    /// `RepoRelocator` against the live model, watchers, and caches.
    @MainActor
    private func relocateRepo(repoIdx: Int, newURL: URL, isStale: Bool) async {
        let oldRepoPath = appState.repos[repoIdx].path
        let newRepoPath = newURL.path

        // (a) Abort if the resolved folder is no longer a git repo.
        let gitEntry = newURL.appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: gitEntry) else {
            NSLog("[Graftty] relocateRepo: resolved URL is not a git repo: %@", newRepoPath)
            return
        }
        // (b) Re-mint stale bookmark.
        if isStale, let fresh = try? RepoBookmark.mint(atPath: newRepoPath) {
            appState.repos[repoIdx].bookmark = fresh
        }
        // (c) Stop old watchers.
        services.worktreeMonitor.stopWatching(repoPath: oldRepoPath)
        for wt in appState.repos[repoIdx].worktrees {
            services.worktreeMonitor.stopWatchingWorktree(wt.path)
        }
        // (d) Clear per-old-path caches.
        for wt in appState.repos[repoIdx].worktrees {
            prStatusStore.clear(worktreePath: wt.path)
            statsStore.clear(worktreePath: wt.path)
        }

        // (e)+(f) Update path/displayName + discover at new location.
        let pre = appState.repos[repoIdx]
        appState.repos[repoIdx].path = newRepoPath
        appState.repos[repoIdx].displayName = newURL.lastPathComponent

        var discovered: [DiscoveredWorktree]
        do {
            discovered = try await GitWorktreeDiscovery.discover(repoPath: newRepoPath)
        } catch {
            NSLog("[Graftty] relocateRepo: discover failed at %@: %@",
                  newRepoPath, String(describing: error))
            return
        }

        // (g) If repair needed, run repair and re-discover.
        let firstDecision = RepoRelocator.decide(
            repo: pre,
            newRepoPath: newRepoPath,
            discovered: discovered,
            selectedWorktreePath: appState.selectedWorktreePath
        )
        let finalDecision: RepoRelocator.Decision
        if firstDecision.needsRepair {
            do {
                try await GitWorktreeRepair.repair(
                    repoPath: newRepoPath,
                    worktreePaths: firstDecision.repairCandidatePaths
                )
                discovered = try await GitWorktreeDiscovery.discover(repoPath: newRepoPath)
            } catch {
                NSLog("[Graftty] relocateRepo: repair failed at %@: %@",
                      newRepoPath, String(describing: error))
            }
            finalDecision = RepoRelocator.decidePostRepair(
                repo: pre,
                newRepoPath: newRepoPath,
                discovered: discovered,
                selectedWorktreePath: appState.selectedWorktreePath
            )
        } else {
            finalDecision = firstDecision
        }

        // (h) Apply carry-forward + stale decisions.
        var newWorktrees: [WorktreeEntry] = []
        for cf in finalDecision.carriedForward {
            if var existing = pre.worktrees.first(where: { $0.id == cf.existingID }) {
                existing.path = cf.newPath
                newWorktrees.append(existing)
            }
        }
        for stale in finalDecision.goneStale {
            if var existing = pre.worktrees.first(where: { $0.id == stale.existingID }) {
                existing.state = .stale
                newWorktrees.append(existing)
            }
        }
        // Fresh (unmatched) discovered entries — new worktrees git added
        // while Graftty wasn't watching.
        let knownBranches = Set(finalDecision.carriedForward.map(\.branch))
            .union(finalDecision.goneStale.map(\.branch))
        for d in discovered where !knownBranches.contains(d.branch) {
            newWorktrees.append(WorktreeEntry(path: d.path, branch: d.branch))
        }
        appState.repos[repoIdx].worktrees = newWorktrees

        // (i) Update selection.
        appState.selectedWorktreePath = finalDecision.newSelectedWorktreePath

        // (j) Install fresh watchers.
        services.worktreeMonitor.watchWorktreeDirectory(repoPath: newRepoPath)
        services.worktreeMonitor.watchOriginRefs(repoPath: newRepoPath)
        for wt in appState.repos[repoIdx].worktrees where wt.state != .stale {
            services.worktreeMonitor.watchWorktreePath(wt.path)
            services.worktreeMonitor.watchHeadRef(worktreePath: wt.path, repoPath: newRepoPath)
            services.worktreeMonitor.watchWorktreeContents(worktreePath: wt.path)
        }

        NSLog("[Graftty] relocated repo %@ → %@", oldRepoPath, newRepoPath)
    }
```

**Note:** depending on whether `relocateRepo`'s surrounding actor isolates it differently from the existing `reconcileOnLaunch` helper, the `@MainActor async` attribute may need to match the existing method's. Inspect `reconcileOnLaunch` (line ~462) and mirror its isolation. If `WorktreeMonitor.watch*` calls are not MainActor-safe in this project, hop off the main actor for them via the pattern already used in `reconcileOnLaunch`.

- [ ] **Step 3: Invoke `resolveRepoLocations()` at the top of `reconcileOnLaunch`**

At the very start of `reconcileOnLaunch`, dispatch the pre-pass:

```swift
    private func reconcileOnLaunch() {
        let binding = $appState
        let statsStore = services.statsStore
        // ...existing locals...

        Task { @MainActor in
            await resolveRepoLocations()
            // ...rest of the existing reconcileOnLaunch body...
        }
    }
```

Inspect the existing structure of `reconcileOnLaunch` to place this correctly — it already wraps a `Task { @MainActor in ... }`, so the new call goes at the top of that closure. If `reconcileOnLaunch` does not already wrap in such a task, add one and put `resolveRepoLocations()` inside.

- [ ] **Step 4: Run `swift build`**

Run: `swift build 2>&1 | tail -30`

Expected: clean. If the `relocateRepo` Task/await shape conflicts with existing MainActor guarantees, the compiler will flag it — fix the isolation annotations to match the neighboring method and retry.

- [ ] **Step 5: Run the test suite**

Run: `swift test 2>&1 | tail -30`

Expected: clean. No test targets this orchestrator directly (the policy tests in Task 5 cover its decision-making); a regression in existing tests would indicate an accidental semantics change.

- [ ] **Step 6: Smoke test the migration path**

1. With `state.json` generated by the pre-Task-8 build (bookmark-less), relaunch Graftty. In the console, verify the repo's stored path still shows correctly. Quit. Inspect `state.json`: the entry should now have a `"bookmark"` blob (migration backfill).

- [ ] **Step 7: Smoke test the launch-time rename path**

1. Quit Graftty.
2. Rename the repo folder in Finder (e.g. `~/code/foo` → `~/code/foo-renamed`).
3. Launch Graftty. The sidebar label updates to `foo-renamed`. Click a worktree inside; terminal opens at the new path.
4. Verify the `state.json` entry reflects the new path.

- [ ] **Step 8: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift
git commit -m "feat(app): launch-time bookmark resolution + migration (LAYOUT-4.6/LAYOUT-4.9)"
```

---

## Task 10: Runtime recovery in `worktreeMonitorDidDetectDeletion` + SPECS.md LAYOUT-4.5..4.10

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift:1488-1510` (the `WorktreeMonitorBridge.worktreeMonitorDidDetectDeletion` method)
- Modify: `SPECS.md` (append LAYOUT-4.5..4.10 under the subsection Task 7 created)

### Why
Second entry point for the relocate cascade. Fires when the user renames the folder *while Graftty is running* — FSEvents delivers a deletion on the old watched path. Hooking the bookmark-resolve before the existing `.stale` transition means the user never sees the yellow stale state for a renamed repo.

- [ ] **Step 1: Add the recovery hook to `worktreeMonitorDidDetectDeletion`**

Modify the method at `Sources/Graftty/GrafttyApp.swift:1488-1510`. The existing body runs the `.stale` transition unconditionally. Insert a pre-step that attempts relocation if the enclosing repo has a bookmark:

```swift
    nonisolated func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String) {
        let binding = appState
        let store = statsStore
        let prStore = prStatusStore
        Task { @MainActor in
            // LAYOUT-4.7: try bookmark-based recovery before marking stale.
            if let (repoIdx, _) = binding.wrappedValue.indices(forWorktreePath: worktreePath),
               let bookmark = binding.wrappedValue.repos[repoIdx].bookmark {
                do {
                    let resolved = try RepoBookmark.resolve(bookmark)
                    if resolved.url.path != binding.wrappedValue.repos[repoIdx].path {
                        await self.espalierDelegate?.relocateRepo(
                            repoIdx: repoIdx,
                            newURL: resolved.url,
                            isStale: resolved.isStale
                        )
                        // Relocate ran — the worktree either moved with it
                        // or went stale via RepoRelocator decisions. Either
                        // way, skip the existing unconditional stale path.
                        return
                    }
                } catch {
                    NSLog("[Graftty] worktreeMonitorDidDetectDeletion: bookmark resolve failed: %@",
                          String(describing: error))
                    // fall through
                }
            }

            // Existing path, unchanged:
            for repoIdx in binding.wrappedValue.repos.indices {
                for wtIdx in binding.wrappedValue.repos[repoIdx].worktrees.indices {
                    if binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == worktreePath {
                        binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .stale
                    }
                }
            }
            store.clear(worktreePath: worktreePath)
            prStore.clear(worktreePath: worktreePath)
            monitor.stopWatchingWorktree(worktreePath)
        }
    }
```

**Note on `espalierDelegate`:** the bridge (`WorktreeMonitorBridge` at line ~1396) holds a weak reference to the `EspalierServices` or `GrafttyApp` view — inspect how other delegate methods route back to the app (e.g. `worktreeMonitorDidDetectChange`) and expose `relocateRepo` via whatever existing channel those methods use. If no such channel exists, add a tight delegate method like:

```swift
@MainActor
protocol RepoRelocateReceiver: AnyObject {
    func relocateRepo(repoIdx: Int, newURL: URL, isStale: Bool) async
}
```

and conform the containing class to it. Do not duplicate the `relocateRepo` body into the bridge — keep it next to `resolveRepoLocations` from Task 9.

- [ ] **Step 2: Update SPECS.md with LAYOUT-4.5..4.10**

Append to the §1.4 subsection Task 7 introduced:

```markdown
#### Relocating (Rename / Move recovery)

**LAYOUT-4.5** When the user adds a repository, the application shall record a `URL` bookmark (`URL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)`) for the repository folder and persist it on the `RepoEntry` alongside the path. Bookmark minting failures shall be non-fatal — the repository entry shall be created with a nil bookmark and forgo auto-recovery.

**LAYOUT-4.6** On launch, before FSEvents watchers are installed, for each repository entry whose bookmark is non-nil, the application shall resolve the bookmark via `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)`. If the resolved path differs from the stored `RepoEntry.path`, the application shall run the relocate cascade described in LAYOUT-4.8. If the bookmark is resolvable but stale (cross-volume move), the application shall re-mint and persist a fresh bookmark from the resolved URL.

**LAYOUT-4.7** When `WorktreeMonitor` reports a deletion event for a worktree path whose owning repository has a non-nil bookmark, the application shall resolve the bookmark and, if the resolved path differs from the stored `RepoEntry.path`, run the relocate cascade described in LAYOUT-4.8 before applying the existing transition-to-`.stale` path (GIT-3.3). If bookmark resolution fails or the resolved folder is no longer a git repository, the application shall fall through to the existing `.stale` path.

**LAYOUT-4.8** The relocate cascade for a repository resolved to `newURL` differing from the stored path shall: (a) verify a `.git` entry exists at `newURL.path`, aborting if not, (b) stop all existing watchers tied to old paths, (c) run `GitWorktreeDiscovery.discover(repoPath: newURL.path)`, running `git worktree repair` and re-discovering if any previously-known linked worktree is omitted from the discovery result, (d) update the `RepoEntry`'s `path` and `displayName` to the new location, (e) match each existing `WorktreeEntry` to a discovered worktree by **branch name** and preserve `id`, `splitTree`, `state`, `focusedTerminalID`, `paneAttention`, `attention`, and `offeredDeleteForMergedPR`, updating only `path`, (f) clear per-path PR-status and divergence-stats cache entries for every worktree whose path changed, (g) update `selectedWorktreePath` from its old path to the corresponding new path if applicable, and (h) re-install repository-level and per-worktree FSEvents watchers at the new paths. Steps (a)–(c) shall precede (d) so that a discovery failure leaves the model unchanged.

**LAYOUT-4.9** For a repository entry loaded from `state.json` without a bookmark (migration from a pre-LAYOUT-4.5 build), the application shall mint a fresh bookmark from the stored `path` if that path still resolves on disk, and persist it.

**LAYOUT-4.10** The application shall use regular (not security-scoped) bookmarks. Security-scoped bookmarks are unnecessary because Graftty is not sandboxed and `NSOpenPanel` already grants the app arbitrary-path URLs.
```

- [ ] **Step 3: Run `swift build`**

Run: `swift build 2>&1 | tail -20`

Expected: clean.

- [ ] **Step 4: Run the test suite**

Run: `swift test 2>&1 | tail -20`

Expected: clean.

- [ ] **Step 5: Smoke test the runtime-rename path**

1. Launch Graftty.
2. Add a repo with at least one linked worktree.
3. With Graftty still running, rename the repo folder in Finder.
4. Observe: the sidebar label updates within a second or two (FSEvents deletion → bookmark resolve → relocate cascade). No `.stale` yellow appears.
5. Click a worktree: terminal opens at the new path.
6. Inspect `state.json`: path and displayName reflect the new folder; bookmark persists.

Report any `.stale` flash or console error.

- [ ] **Step 6: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift SPECS.md
git commit -m "feat(app): runtime rename recovery via bookmark resolve (LAYOUT-4.5 .. LAYOUT-4.10)"
```

---

## Task 11: Run `/simplify` on the changeset

**Files:** all modified files in the branch diff.

### Why
The spec explicitly requested a simplify pass after implementation. `/simplify` reviews recently-modified code for reuse, quality, and efficiency and fixes any issues found. Running this task as its own step means its result lands as a dedicated, reviewable commit rather than mixing into feature commits.

- [ ] **Step 1: Invoke simplify**

At the Claude Code prompt (or equivalent): `/simplify`

Let it review the staged/unstaged changes and the diff against `origin/main`.

- [ ] **Step 2: Review its proposed changes**

Accept only the ones that demonstrably improve clarity without changing behavior or breaking a named test. Reject anything that:
- Loosens error handling ("just return nil").
- Removes `NSLog` diagnostics (the codebase uses them deliberately per GIT-3.12 / ATTN-2.7 / PERSIST-2.2 patterns).
- Introduces premature abstractions.

- [ ] **Step 3: Run the full test suite once more**

Run: `swift test 2>&1 | tail -30`

Expected: all pass.

- [ ] **Step 4: Commit simplify changes (if any)**

```bash
git add -p  # stage intentionally — do not bulk-add
git commit -m "refactor: simplify repository-lifecycle changeset"
```

If simplify proposed nothing worth keeping, skip this commit.

---

## Task 12: Push and open the PR

**Files:** none (git metadata only).

### Why
Final delivery step requested by the user.

- [ ] **Step 1: Push the branch**

Run: `git push -u origin right-click-on-repository-to-remove`

Expected: remote tracking set up; all new commits visible on GitHub.

- [ ] **Step 2: Open the PR**

Use `gh pr create` with a body summarizing both feature families. Use a HEREDOC for formatting:

```bash
gh pr create --title "feat(sidebar): Remove Repository + rename-recovery (LAYOUT-4.1..4.10)" --body "$(cat <<'EOF'
## Summary

- Right-click on a repository row in the sidebar to **Remove Repository** — removes from Graftty, leaves files on disk untouched.
- When a tracked repo folder is renamed or moved in Finder, Graftty transparently reconnects using a persisted macOS URL bookmark. Sidebar label updates; no `.stale` flash; no dialog. `git worktree repair` runs automatically if linked worktrees' `gitdir` pointers break.

Spec: `docs/superpowers/specs/2026-04-21-repository-lifecycle-design.md`
Plan: `docs/superpowers/plans/2026-04-21-repository-lifecycle.md`

Adds SPECS.md entries **LAYOUT-4.1 .. LAYOUT-4.10**.

## Test plan

- [ ] `swift test` passes locally.
- [ ] Manually: Add → right-click → Remove Repository → folder intact on disk.
- [ ] Manually: Quit → rename repo in Finder → launch → sidebar reflects new name; worktrees open.
- [ ] Manually: Running app → rename repo in Finder → no `.stale` flash → label updates → worktrees still work.
- [ ] Manually: Migration — launch with a pre-bookmark `state.json`; verify bookmark backfills.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Verify the PR URL**

Expected: `gh pr create` prints a GitHub URL. Open it and confirm the description rendered.

---

## Self-Review

Ran after writing all 12 tasks:

1. **Spec coverage.**
   - LAYOUT-4.1 (right-click menu) → Task 6 + Task 7 ✓
   - LAYOUT-4.2 (confirm dialog text) → Task 7 ✓
   - LAYOUT-4.3 (cascade ordering a..e) → Task 7 ✓
   - LAYOUT-4.4 (no git, no disk changes) → Task 7 ✓
   - LAYOUT-4.5 (mint bookmark on add) → Task 8 ✓
   - LAYOUT-4.6 (launch-time resolve) → Task 9 ✓
   - LAYOUT-4.7 (runtime deletion-event recovery) → Task 10 ✓
   - LAYOUT-4.8 (relocate cascade semantics) → Task 5 + Task 9 ✓
   - LAYOUT-4.9 (backfill mint for bookmarkless entries) → Task 9 ✓
   - LAYOUT-4.10 (non-security-scoped) → Task 3 (`RepoBookmark`) + Task 10 SPECS ✓
   - `AppState.removeRepo` selection-clear → Task 1 ✓
   - `RepoEntry.bookmark` schema + `path` var + Codable migration → Task 2 ✓
   - `RepoBookmark`, `GitWorktreeRepair`, `RepoRelocator` modules → Tasks 3-5 ✓
   - Simplify + PR → Tasks 11-12 ✓

2. **Placeholder scan.** All "implement later" / "TBD" / "handle edge cases" patterns checked. One deferred judgment call remains in Task 4 ("Verify these exist by inspecting … adapt to match the real ones") — kept deliberate because the test-harness API is a sibling file's concern and the subagent should verify rather than blindly assume.

3. **Type consistency.**
   - `RepoBookmark.Resolved` defined in Task 3 with `url: URL, isStale: Bool` — used in Tasks 9 and 10 consistently.
   - `RepoRelocator.Decision` defined in Task 5 with `needsRepair / repairCandidatePaths / carriedForward / goneStale / newSelectedWorktreePath` — consumed in Task 9 with the same names.
   - `CarryForward.existingID` / `CarryForward.newPath` — used in Task 9 to re-slot existing worktrees; matches.
   - `GitWorktreeRepair.repair(repoPath:worktreePaths:)` — signature matches Task 4 definition and Task 9 call site.
   - `DiscoveredWorktree(path:branch:)` — this is the existing `GitWorktreeDiscovery` result type; tests in Task 5 assume its existence. Verify in `Sources/GrafttyKit/Git/GitWorktreeDiscovery.swift` when implementing.

---

**Plan complete and saved to `docs/superpowers/plans/2026-04-21-repository-lifecycle.md`.**
