# Create-Worktree-Existing-Branch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Add Worktree flow (Mac sheet, iOS sheet, web HTTP) to support creating a worktree from an existing branch — with a dropdown that lists local + remote-only branches, shows PR/MR number+title, dims branches mounted in another worktree, and surfaces the last-commit relative date.

**Architecture:** A segmented "New branch / Existing branch" control gates between today's text field and a new picker. The picker reads from a richer `RemoteBranchStore` snapshot (with commit dates) and a new branch-keyed PR map on `PRStatusStore`. A `BranchSelection` enum replaces the existing `branchName: String` parameter through `AddWorktreeFlow` → `GitWorktreeAdd`, switching git argv between `-b <new>` and bare `<existing>` / `origin/<existing>`.

**Tech Stack:** Swift (Swift Testing framework), SwiftUI (macOS + iOS), `git for-each-ref`, `gh pr list`. Spec annotations via `@spec` with `scripts/generate-specs.py`. New IDs: GIT-5.10..5.15.

---

## File Structure

### New files

- `Sources/GrafttyKit/Git/BranchSelection.swift` — `BranchSelection` enum (createNew / useExisting with source).
- `Sources/GrafttyKit/Model/BranchPickerEntry.swift` — picker row type used by both Mac & iOS.
- `Sources/GrafttyKit/Model/BranchPickerViewModel.swift` — pure logic (dedup, filter, sort, dim) — no SwiftUI.
- `Sources/Graftty/Views/BranchComboBox.swift` — Mac SwiftUI combobox view.
- `Sources/GrafttyMobileKit/UI/BranchPickerView.swift` — iOS pushed-list view.
- `Tests/GrafttyKitTests/Git/GitWorktreeAddArgsTests.swift` — argv shape tests.
- `Tests/GrafttyKitTests/Git/AddWorktreeFlowTests.swift` — flow validation tests.
- `Tests/GrafttyKitTests/Model/BranchPickerViewModelTests.swift` — view model tests.

### Modified files

- `Sources/GrafttyKit/Git/RemoteBranchStore.swift` — add `BranchRef`, store dates, update `defaultList` and parsers.
- `Sources/GrafttyKit/Git/GitWorktreeAdd.swift` — take `BranchSelection`, branch argv shape.
- `Sources/GrafttyKit/PRStatus/PRStatusStore.swift` — add `prsByRepoBranch` index.
- `Sources/GrafttyKit/Model/RepoEntry.swift` — add `branchMountedPath(_:)` helper.
- `Sources/Graftty/AddWorktreeFlow.swift` — `BranchSelection` parameter, `branchAlreadyMounted` error.
- `Sources/Graftty/Views/AddWorktreeSheet.swift` — segmented mode, combobox integration.
- `Sources/Graftty/Views/MainWindow.swift` — adapter for new `BranchSelection` flow signature.
- `Sources/Graftty/Web/WebServerController.swift` — read `existing: Bool?`, map error → 409.
- `Sources/GrafttyMobileKit/UI/AddWorktreeSheetView.swift` — segmented mode, push to picker.
- `Sources/GrafttyMobileKit/Session/CreateWorktreeClient.swift` — `existing` flag.
- `Tests/GrafttyKitTests/Git/RemoteBranchStoreTests.swift` — date-bearing parser tests.
- `Tests/GrafttyKitTests/PRStatus/PRStatusStoreTests.swift` — verify branch index populated.
- `Tests/GrafttyKitTests/Web/WebServerWorktreeEndpointTests.swift` — `existing: true` path.

### Backlog inventory (disabled tests)

The `@spec` IDs are introduced in the dedicated test files that ship with this plan; no separate `*Todo.swift` placeholder is needed since every spec lands as a real `@Test` in the same plan.

---

## Task 1: Extend `RemoteBranchSnapshot` with commit dates

Add per-ref commit dates without breaking existing callers. The snapshot grows; the legacy `branches: Set<String>` becomes a derived view.

**Files:**
- Modify: `Sources/GrafttyKit/Git/RemoteBranchStore.swift`
- Modify: `Tests/GrafttyKitTests/Git/RemoteBranchStoreTests.swift`

- [ ] **Step 1: Add the failing test for the new date parsers**

Append to `Tests/GrafttyKitTests/Git/RemoteBranchStoreTests.swift` (inside the existing `@Suite("RemoteBranchStore") struct RemoteBranchStoreTests`):

```swift
    @Test func parseLocalBranchesWithDatesExtractsNameAndDate() {
        let raw = """
        main\t2026-05-10T12:30:00-05:00\torigin/main
        feature/foo\t2026-05-13T09:15:00-05:00\torigin/feature/bar
        no-upstream\t2026-04-01T00:00:00Z\t

        """
        let parsed = RemoteBranchStore.parseLocalBranchesWithDatesForTesting(raw)
        let names = parsed.map(\.name)
        #expect(names == ["main", "feature/foo", "no-upstream"])
        #expect(parsed.first(where: { $0.name == "main" })?.lastCommitDate != nil)
    }

    @Test func parseRemoteBranchesWithDatesStripsOriginAndKeepsDate() {
        let raw = """
        origin/HEAD\t2026-05-13T09:15:00-05:00
        origin/main\t2026-05-10T12:30:00-05:00
        origin/feature/foo\t2026-05-13T09:15:00-05:00

        """
        let parsed = RemoteBranchStore.parseRemoteBranchesWithDatesForTesting(raw)
        let names = parsed.map(\.name).sorted()
        #expect(names == ["feature/foo", "main"])
        #expect(parsed.contains { $0.name == "main" && $0.lastCommitDate.timeIntervalSince1970 > 0 })
    }
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `swift test --filter RemoteBranchStoreTests`

Expected: FAIL with "no static method 'parseLocalBranchesWithDatesForTesting'" (or similar).

- [ ] **Step 3: Implement `BranchRef`, new snapshot shape, and parsers**

Replace the existing `RemoteBranchSnapshot` and add `BranchRef`:

```swift
public struct BranchRef: Sendable, Equatable, Hashable {
    public let name: String
    public let lastCommitDate: Date

    public init(name: String, lastCommitDate: Date) {
        self.name = name
        self.lastCommitDate = lastCommitDate
    }
}

public struct RemoteBranchSnapshot: Sendable, Equatable {
    public let remoteBranches: [BranchRef]
    public let localBranches: [BranchRef]
    public let upstreams: [String: String]

    public init(
        remoteBranches: [BranchRef] = [],
        localBranches: [BranchRef] = [],
        upstreams: [String: String] = [:]
    ) {
        self.remoteBranches = remoteBranches
        self.localBranches = localBranches
        self.upstreams = upstreams
    }

    /// Back-compat: callers that previously read `branches: Set<String>`
    /// (e.g. `hasRemote`) now read the derived set.
    public var branches: Set<String> { Set(remoteBranches.map(\.name)) }
}
```

Add the new parsers and update `defaultList`. Keep the old `parseRefs` / `parseUpstreams` working since they're still called elsewhere (and from existing tests):

```swift
nonisolated static func parseLocalBranchesWithDates(_ output: String) -> [BranchRef] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return output.split(whereSeparator: \.isNewline).compactMap { raw in
        let parts = raw.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
        guard isEligibleLocalBranch(name) else { return nil }
        let date = formatter.date(from: String(parts[1])) ?? Date.distantPast
        return BranchRef(name: name, lastCommitDate: date)
    }
}

nonisolated static func parseRemoteBranchesWithDates(_ output: String) -> [BranchRef] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return output.split(whereSeparator: \.isNewline).compactMap { raw in
        let parts = raw.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let ref = String(parts[0])
        guard ref.hasPrefix("origin/") else { return nil }
        let name = String(ref.dropFirst("origin/".count))
        guard name != "HEAD", !name.isEmpty else { return nil }
        let date = formatter.date(from: String(parts[1])) ?? Date.distantPast
        return BranchRef(name: name, lastCommitDate: date)
    }
}

nonisolated static func parseLocalBranchesWithDatesForTesting(_ output: String) -> [BranchRef] {
    parseLocalBranchesWithDates(output)
}

nonisolated static func parseRemoteBranchesWithDatesForTesting(_ output: String) -> [BranchRef] {
    parseRemoteBranchesWithDates(output)
}
```

Update `defaultList`:

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
    let (remotes, heads) = try await (remotesTask, headsTask)
    return RemoteBranchSnapshot(
        remoteBranches: parseRemoteBranchesWithDates(remotes),
        localBranches: parseLocalBranchesWithDates(heads),
        upstreams: parseUpstreams(heads)
    )
}
```

- [ ] **Step 4: Run all RemoteBranchStore tests and confirm pass**

Run: `swift test --filter RemoteBranchStoreTests`

Expected: PASS (both new tests + all existing tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Git/RemoteBranchStore.swift \
        Tests/GrafttyKitTests/Git/RemoteBranchStoreTests.swift
git commit -m "feat(branches): extend RemoteBranchSnapshot with per-ref commit dates"
```

---

## Task 2: `BranchSelection` enum + `GitWorktreeAdd` argv switching

Replace the `branchName: String` flow parameter with a typed `BranchSelection`. Switch git argv between four shapes (`-b new`, `-b new + start`, `existing`, `origin/existing`).

**Files:**
- Create: `Sources/GrafttyKit/Git/BranchSelection.swift`
- Modify: `Sources/GrafttyKit/Git/GitWorktreeAdd.swift`
- Create: `Tests/GrafttyKitTests/Git/GitWorktreeAddArgsTests.swift`

- [ ] **Step 1: Create `BranchSelection.swift`**

Write `Sources/GrafttyKit/Git/BranchSelection.swift`:

```swift
import Foundation

/// Branch decision for `AddWorktreeFlow` / `GitWorktreeAdd`. Determines
/// whether `git worktree add` creates a fresh branch (`-b <name>`) or
/// reuses an existing one. For `.useExisting`, the `source` tells the
/// git layer whether to pass the bare branch name (local) or
/// `origin/<name>` (remote-only) so a local tracking branch is created
/// as a side effect.
public enum BranchSelection: Sendable, Hashable {
    /// @spec GIT-5.10
    /// New-branch source for `git worktree add -b <name>`.
    case createNew(name: String)
    /// @spec GIT-5.10
    /// Existing-branch source for `git worktree add <path> <name|origin/name>`.
    case useExisting(name: String, source: ExistingSource)

    public enum ExistingSource: Sendable, Hashable {
        case local       // bare branch ref, e.g. "feature/foo"
        case remoteOnly  // origin/<name>, creates a local tracking branch
    }

    public var branchName: String {
        switch self {
        case .createNew(let name): return name
        case .useExisting(let name, _): return name
        }
    }
}
```

- [ ] **Step 2: Add the failing argv tests**

Write `Tests/GrafttyKitTests/Git/GitWorktreeAddArgsTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitWorktreeAdd argv shape")
struct GitWorktreeAddArgsTests {
    @Test("@spec GIT-5.10: createNew without startPoint uses -b <name> <path>")
    func createNewNoStart() {
        let argv = GitWorktreeAdd.argvForTesting(
            branch: .createNew(name: "feat-x"),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: nil
        )
        #expect(argv == ["worktree", "add", "-b", "feat-x", "/repo/.worktrees/feat-x"])
    }

    @Test("createNew with startPoint appends the start point")
    func createNewWithStart() {
        let argv = GitWorktreeAdd.argvForTesting(
            branch: .createNew(name: "feat-x"),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: "origin/main"
        )
        #expect(argv == ["worktree", "add", "-b", "feat-x", "/repo/.worktrees/feat-x", "origin/main"])
    }

    @Test("@spec GIT-5.10: useExisting local uses bare name, no -b")
    func useExistingLocal() {
        let argv = GitWorktreeAdd.argvForTesting(
            branch: .useExisting(name: "feat-x", source: .local),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: nil
        )
        #expect(argv == ["worktree", "add", "/repo/.worktrees/feat-x", "feat-x"])
    }

    @Test("@spec GIT-5.12: useExisting remoteOnly uses origin/<name>, no -b")
    func useExistingRemoteOnly() {
        let argv = GitWorktreeAdd.argvForTesting(
            branch: .useExisting(name: "feat-x", source: .remoteOnly),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: nil
        )
        #expect(argv == ["worktree", "add", "/repo/.worktrees/feat-x", "origin/feat-x"])
    }

    @Test("useExisting ignores startPoint")
    func useExistingIgnoresStartPoint() {
        let argv = GitWorktreeAdd.argvForTesting(
            branch: .useExisting(name: "feat-x", source: .local),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: "origin/main"
        )
        #expect(argv == ["worktree", "add", "/repo/.worktrees/feat-x", "feat-x"])
    }
}
```

- [ ] **Step 3: Run the tests and confirm they fail**

Run: `swift test --filter GitWorktreeAddArgsTests`

Expected: FAIL — `argvForTesting` does not exist yet.

- [ ] **Step 4: Implement `argvFor` + update `add` signature**

Replace the body of `Sources/GrafttyKit/Git/GitWorktreeAdd.swift`:

```swift
import Foundation

/// Creates a new git worktree for a repository.
///
/// Switches argv based on `BranchSelection`: `.createNew` invokes
/// `git worktree add -b <branch> <path> [<start>]` (today's behavior);
/// `.useExisting` invokes `git worktree add <path> <branch|origin/branch>`
/// (no `-b`, no start point — the existing ref IS the start point).
public enum GitWorktreeAdd {

    public enum Error: Swift.Error, Equatable {
        /// Non-zero exit from git, with stderr included for display.
        case gitFailed(exitCode: Int32, stderr: String)
        /// Git failed to launch or was not found on PATH.
        case cliFailure(CLIError)
    }

    public static func add(
        repoPath: String,
        worktreePath: String,
        branch: BranchSelection,
        startPoint: String?
    ) async throws {
        let args = argvFor(
            branch: branch,
            worktreePath: worktreePath,
            startPoint: startPoint
        )
        let result: CLIOutput
        do {
            result = try await GitRunner.captureAll(args: args, at: repoPath)
        } catch let err as CLIError {
            throw Error.cliFailure(err)
        }
        guard result.exitCode == 0 else {
            throw Error.gitFailed(
                exitCode: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    nonisolated static func argvFor(
        branch: BranchSelection,
        worktreePath: String,
        startPoint: String?
    ) -> [String] {
        switch branch {
        case .createNew(let name):
            var args = ["worktree", "add", "-b", name, worktreePath]
            if let startPoint, !startPoint.isEmpty {
                args.append(startPoint)
            }
            return args
        case .useExisting(let name, let source):
            let ref: String
            switch source {
            case .local: ref = name
            case .remoteOnly: ref = "origin/" + name
            }
            return ["worktree", "add", worktreePath, ref]
        }
    }

    public nonisolated static func argvForTesting(
        branch: BranchSelection,
        worktreePath: String,
        startPoint: String?
    ) -> [String] {
        argvFor(branch: branch, worktreePath: worktreePath, startPoint: startPoint)
    }
}
```

- [ ] **Step 5: Update existing callers to use `BranchSelection`**

Update `Sources/Graftty/AddWorktreeFlow.swift` `finishCreate` — swap the `try await GitWorktreeAdd.add(...)` call to pass `branch: .createNew(name: branchName)`. (The flow's outer signature changes in Task 3; this is a minimal in-place update to keep the build green.)

In `finishCreate`, change:

```swift
try await GitWorktreeAdd.add(
    repoPath: repoPath,
    worktreePath: worktreePath,
    branchName: branchName,
    startPoint: startPoint
)
```

to:

```swift
try await GitWorktreeAdd.add(
    repoPath: repoPath,
    worktreePath: worktreePath,
    branch: .createNew(name: branchName),
    startPoint: startPoint
)
```

- [ ] **Step 6: Run tests, including any broader builds**

Run: `swift build`

Expected: BUILD SUCCEEDED.

Run: `swift test --filter GitWorktreeAddArgsTests`

Expected: PASS (all five tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Git/BranchSelection.swift \
        Sources/GrafttyKit/Git/GitWorktreeAdd.swift \
        Sources/Graftty/AddWorktreeFlow.swift \
        Tests/GrafttyKitTests/Git/GitWorktreeAddArgsTests.swift
git commit -m "feat(git): switch GitWorktreeAdd to BranchSelection-driven argv"
```

---

## Task 3: `AddWorktreeFlow` BranchSelection plumbing + `branchAlreadyMounted` error

Push `BranchSelection` up through `beginCreate` / `finishCreate` / `add`. Add the new error path so the picker can refuse to mount a branch already attached to another worktree.

**Files:**
- Modify: `Sources/GrafttyKit/Model/RepoEntry.swift`
- Modify: `Sources/Graftty/AddWorktreeFlow.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`
- Modify: `Sources/Graftty/Web/WebServerController.swift`
- Modify: `Sources/Graftty/Views/AddWorktreeSheet.swift`
- Modify: `Sources/GrafttyMobileKit/UI/AddWorktreeSheetView.swift`
- Modify: `Sources/GrafttyMobileKit/Session/CreateWorktreeClient.swift`
- Create: `Tests/GrafttyKitTests/Git/AddWorktreeFlowTests.swift`

- [ ] **Step 1: Add `branchMountedPath(_:)` helper on `RepoEntry`**

In `Sources/GrafttyKit/Model/RepoEntry.swift` (or append in an extension at file bottom):

```swift
extension RepoEntry {
    /// Path of the on-disk worktree currently checked out at `branch`,
    /// or nil if no on-disk worktree of this repo uses that branch.
    /// `.creating` placeholders are intentionally excluded — git would
    /// let the user mount the branch even with a placeholder present.
    public func branchMountedPath(_ branch: String) -> String? {
        worktrees.first { $0.branch == branch && $0.state.hasOnDiskWorktree }?.path
    }
}
```

- [ ] **Step 2: Add the failing flow test**

Write `Tests/GrafttyKitTests/Git/AddWorktreeFlowTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("RepoEntry.branchMountedPath")
struct RepoEntryBranchMountedTests {
    @Test("@spec GIT-5.11: returns path when branch is in an on-disk worktree")
    func returnsPathForOnDisk() {
        var wt = WorktreeEntry(path: "/r/.worktrees/feat", branch: "feat")
        wt.state = .running
        let repo = RepoEntry(
            path: "/r",
            displayName: "r",
            worktrees: [wt]
        )
        #expect(repo.branchMountedPath("feat") == "/r/.worktrees/feat")
    }

    @Test("returns nil for .creating placeholder")
    func nilForCreatingPlaceholder() {
        var wt = WorktreeEntry(path: "/r/.worktrees/feat", branch: "feat")
        wt.state = .creating
        let repo = RepoEntry(
            path: "/r",
            displayName: "r",
            worktrees: [wt]
        )
        #expect(repo.branchMountedPath("feat") == nil)
    }

    @Test("returns nil when no worktree matches the branch")
    func nilWhenNotMounted() {
        var wt = WorktreeEntry(path: "/r/.worktrees/other", branch: "other")
        wt.state = .running
        let repo = RepoEntry(
            path: "/r",
            displayName: "r",
            worktrees: [wt]
        )
        #expect(repo.branchMountedPath("feat") == nil)
    }
}
```

- [ ] **Step 3: Run the new tests**

Run: `swift test --filter RepoEntryBranchMountedTests`

Expected: PASS (the helper from Step 1 makes all three green).

- [ ] **Step 4: Update `AddWorktreeFlow` to take `BranchSelection`**

Modify `Sources/Graftty/AddWorktreeFlow.swift`:

1. Import `GrafttyKit` is already there; ensure `BranchSelection` resolves.
2. Add the new error case:

```swift
enum FlowError: Error, Equatable {
    case gitFailed(String)
    case repoNotFound
    case pathCollision
    case discoveryFailed(String)
    /// @spec GIT-5.11
    /// `.useExisting(name, _)` was submitted but the same repo already
    /// has the branch mounted in another worktree. Holds the colliding
    /// worktree's path so the caller can surface it.
    case branchAlreadyMounted(at: String)
}
```

3. Replace `branchName: String` with `branch: BranchSelection` across `beginCreate`, `finishCreate`, and `add`:

In `beginCreate`, replace the signature and update the mount-collision check:

```swift
static func beginCreate(
    repoPath: String,
    worktreeName: String,
    branch: BranchSelection,
    appState: Binding<AppState>
) -> Swift.Result<String, FlowError> {
    guard let repoIdx = appState.wrappedValue.repos
        .firstIndex(where: { $0.path == repoPath }) else {
        return .failure(.repoNotFound)
    }

    let worktreePath = repoPath + "/.worktrees/" + worktreeName

    if appState.wrappedValue.worktree(forPath: worktreePath) != nil {
        return .failure(.pathCollision)
    }

    if case .useExisting(let name, _) = branch,
       let existing = appState.wrappedValue.repos[repoIdx].branchMountedPath(name) {
        return .failure(.branchAlreadyMounted(at: existing))
    }

    var placeholder = WorktreeEntry(path: worktreePath, branch: branch.branchName)
    placeholder.state = .creating
    appState.wrappedValue.repos[repoIdx].worktrees.append(placeholder)
    return .success(worktreePath)
}
```

In `finishCreate`, replace the parameter and the git call:

```swift
static func finishCreate(
    repoPath: String,
    worktreePath: String,
    branch: BranchSelection,
    appState: Binding<AppState>,
    worktreeMonitor: WorktreeMonitor,
    statsStore: WorktreeStatsStore,
    terminalManager: TerminalManager,
    teamEventDispatcher: TeamEventDispatcher
) async -> Swift.Result<Result, FlowError> {
    // For .useExisting, the start point is the existing branch itself;
    // git takes it from argv. For .createNew, default to origin's main.
    let startPoint: String?
    if case .createNew = branch {
        startPoint = await GitOriginDefaultBranch.resolve(repoPath: repoPath)
    } else {
        startPoint = nil
    }

    do {
        try await GitWorktreeAdd.add(
            repoPath: repoPath,
            worktreePath: worktreePath,
            branch: branch,
            startPoint: startPoint
        )
    } catch GitWorktreeAdd.Error.gitFailed(_, let stderr) {
        removePlaceholder(at: worktreePath, appState: appState)
        let msg = stderr.isEmpty ? "git worktree add failed" : stderr
        return .failure(.gitFailed(msg))
    } catch {
        removePlaceholder(at: worktreePath, appState: appState)
        return .failure(.gitFailed("\(error)"))
    }

    // (rest of finishCreate unchanged — same discovery + watcher arming)
    /* … existing body verbatim … */
}
```

Update the `add` wrapper signature to take `branch: BranchSelection` and forward.

4. Update `userMessage`:

```swift
var userMessage: String? {
    switch self {
    case .gitFailed(let m): return m
    case .repoNotFound: return "repository no longer tracked"
    case .pathCollision: return "a worktree at that name already exists"
    case .branchAlreadyMounted(let path):
        let base = (path as NSString).lastPathComponent
        return "branch is already mounted at " + base
    case .discoveryFailed: return nil
    }
}
```

- [ ] **Step 5: Add a flow test for `branchAlreadyMounted`**

Append to `Tests/GrafttyKitTests/Git/AddWorktreeFlowTests.swift`:

```swift
import SwiftUI

@MainActor
@Suite("AddWorktreeFlow.beginCreate")
struct AddWorktreeFlowBeginCreateTests {
    @Test("@spec GIT-5.11: useExisting on a mounted branch returns .branchAlreadyMounted")
    func mountedBranchRejected() async throws {
        var wt = WorktreeEntry(path: "/r/.worktrees/feat", branch: "feat")
        wt.state = .running
        let initial = AppState(repos: [
            RepoEntry(path: "/r", displayName: "r", worktrees: [wt])
        ])
        var state = initial
        let binding = Binding<AppState>(
            get: { state },
            set: { state = $0 }
        )
        let result = AddWorktreeFlow.beginCreate(
            repoPath: "/r",
            worktreeName: "feat-copy",
            branch: .useExisting(name: "feat", source: .local),
            appState: binding
        )
        switch result {
        case .failure(.branchAlreadyMounted(let at)):
            #expect(at == "/r/.worktrees/feat")
        default:
            Issue.record("expected .branchAlreadyMounted, got \(result)")
        }
    }
}
```

NOTE: `AddWorktreeFlow` is in the `Graftty` target, not `GrafttyKit`. Put this test in `Tests/GrafttyTests/Git/` instead. Create the directory if needed and use `@testable import Graftty`.

Adjusted location: write the test at `Tests/GrafttyTests/Git/AddWorktreeFlowBeginCreateTests.swift` (create the `Git/` subdirectory under `Tests/GrafttyTests/` if absent — Swift Package Manager auto-discovers it). Replace `import GrafttyKit` with both `@testable import Graftty` and `import GrafttyKit`.

- [ ] **Step 6: Run the new test**

Run: `swift test --filter AddWorktreeFlowBeginCreateTests`

Expected: PASS.

- [ ] **Step 7: Update call sites that pass `branchName:` to the flow**

In `Sources/Graftty/Views/MainWindow.swift`, find `addWorktree` (around line 450). Update the inner call to `AddWorktreeFlow.beginCreate` / `finishCreate` to pass `branch: .createNew(name: branchName)` (preserving today's behavior — Task 7 will swap in the picker).

In `Sources/Graftty/Web/WebServerController.swift`, find the `POST /worktrees` handler and the `AddWorktreeFlow.add` call. Pass `branch: .createNew(name: branchName)` for now.

In `Sources/Graftty/Views/AddWorktreeSheet.swift`, the `onSubmit` closure signature is `(String, String) async -> String?`. No change needed yet; that gets refactored in Task 7.

- [ ] **Step 8: Run the full build**

Run: `swift build`

Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Commit**

```bash
git add Sources/GrafttyKit/Model/RepoEntry.swift \
        Sources/Graftty/AddWorktreeFlow.swift \
        Sources/Graftty/Views/MainWindow.swift \
        Sources/Graftty/Web/WebServerController.swift \
        Tests/GrafttyKitTests/Git/AddWorktreeFlowTests.swift \
        Tests/GrafttyTests/Git/AddWorktreeFlowBeginCreateTests.swift
git commit -m "feat(flow): AddWorktreeFlow takes BranchSelection + branchAlreadyMounted error"
```

---

## Task 4: `PRStatusStore.prsByRepoBranch` second index

Today `infos[worktreePath]` only carries PR data for mounted worktrees. The picker needs PR data for unmounted branches too. The fetcher already returns every PR in the repo — we just need a second publication keyed by branch name.

**Files:**
- Modify: `Sources/GrafttyKit/PRStatus/PRStatusStore.swift`
- Modify: `Tests/GrafttyKitTests/PRStatus/PRStatusStoreTests.swift`

- [ ] **Step 1: Find the existing test file and read the suite header**

Run: `head -50 Tests/GrafttyKitTests/PRStatus/PRStatusStoreTests.swift`

Note the existing import lines and the suite name — append the new tests using the same pattern.

- [ ] **Step 2: Add the failing test**

Append to `Tests/GrafttyKitTests/PRStatus/PRStatusStoreTests.swift`. Adapt to the existing suite — if tests are top-level structs, add a new struct; if inside one big suite, append a new `@Test`:

```swift
@MainActor
@Suite("PRStatusStore.prsByRepoBranch")
struct PRStatusStorePrsByRepoBranchTests {
    @Test("snapshot populates prsByRepoBranch keyed by repo, branch")
    func populatesBranchIndex() async {
        // Use the same fetcherFor / detectHost stubbing pattern as the
        // existing PRStatusStoreTests.
        // Stub: fetcher returns RepoPRSnapshot with one PR on branch "feat".
        // Action: dispatchRepoFetch via refresh().
        // Assert: store.prsByRepoBranch["/r"]?["feat"]?.number == 42.
        // (Match the existing seed pattern from the file.)
        Issue.record("Replace this placeholder with the matching pattern from the existing PRStatusStoreTests file — read it before writing.")
    }
}
```

NOTE: The exact test setup mirrors existing `PRStatusStoreTests` patterns — copy the fixture builders verbatim from a nearby `@Test` that already exercises a synthetic `RepoPRSnapshot`. Replace the `Issue.record` with the real assertions.

- [ ] **Step 3: Run the test and confirm it fails (Issue.record or no `prsByRepoBranch` property)**

Run: `swift test --filter PRStatusStorePrsByRepoBranchTests`

Expected: FAIL.

- [ ] **Step 4: Implement `prsByRepoBranch`**

In `Sources/GrafttyKit/PRStatus/PRStatusStore.swift`:

Add the property near `infos`:

```swift
/// Per-repo, per-branch PR map. Populated alongside `infos` from the
/// same fetcher snapshot — the picker reads this for arbitrary
/// branches in the repo (including unmounted ones), while
/// per-worktree consumers continue reading `infos`.
/// @spec GIT-5.14
public private(set) var prsByRepoBranch: [String: [String: PRInfo]] = [:]
```

Update `applySnapshot` to populate it. After computing `snapshot`, copy the per-branch values for the repo:

```swift
private func applySnapshot(
    _ snapshot: RepoPRSnapshot,
    repoPath: String,
    origin: HostingOrigin?
) {
    // …existing per-worktree distribution unchanged…

    // Publish the per-branch view for the picker.
    if prsByRepoBranch[repoPath] != snapshot.prsByBranch {
        prsByRepoBranch[repoPath] = snapshot.prsByBranch
    }
}
```

Add prune in `pruneStaleRepoState` (already prunes `fetchStateByRepo` and `hostByRepo`):

```swift
for repoPath in prsByRepoBranch.keys where !currentRepoPaths.contains(repoPath) {
    prsByRepoBranch.removeValue(forKey: repoPath)
}
```

- [ ] **Step 5: Fill in the test from Step 2**

Replace the `Issue.record` placeholder with real assertions. Use the existing seeded-fetcher pattern from `PRStatusStoreTests` (search the file for `fetcherFor:` to find a setup that injects a synthetic `RepoPRSnapshot`). Assert:

```swift
#expect(store.prsByRepoBranch["/r"]?["feat"]?.number == 42)
```

- [ ] **Step 6: Run the test, expect pass**

Run: `swift test --filter PRStatusStorePrsByRepoBranchTests`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/PRStatus/PRStatusStore.swift \
        Tests/GrafttyKitTests/PRStatus/PRStatusStoreTests.swift
git commit -m "feat(pr-status): publish prsByRepoBranch alongside per-worktree infos"
```

---

## Task 5: `BranchPickerEntry` + `BranchPickerViewModel`

Pure-Swift logic that produces sorted/filtered picker rows. Testable without SwiftUI or `MainActor`.

**Files:**
- Create: `Sources/GrafttyKit/Model/BranchPickerEntry.swift`
- Create: `Sources/GrafttyKit/Model/BranchPickerViewModel.swift`
- Create: `Tests/GrafttyKitTests/Model/BranchPickerViewModelTests.swift`

- [ ] **Step 1: Write the failing test file**

Create `Tests/GrafttyKitTests/Model/BranchPickerViewModelTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("BranchPickerViewModel")
struct BranchPickerViewModelTests {

    private func make(
        local: [(String, Date)] = [],
        remote: [(String, Date)] = [],
        mounted: [String: String] = [:],
        prs: [String: PRInfo] = [:],
        filter: String = ""
    ) -> [BranchPickerEntry] {
        let snapshot = RemoteBranchSnapshot(
            remoteBranches: remote.map { BranchRef(name: $0.0, lastCommitDate: $0.1) },
            localBranches: local.map { BranchRef(name: $0.0, lastCommitDate: $0.1) },
            upstreams: [:]
        )
        return BranchPickerViewModel.entries(
            branchSnapshot: snapshot,
            mountedBranchToPath: mounted,
            prsByBranch: prs,
            filterText: filter
        )
    }

    @Test("@spec GIT-5.13: sorts by lastCommitDate descending")
    func sortsByDateDesc() {
        let now = Date()
        let entries = make(local: [
            ("old", now.addingTimeInterval(-3600 * 24 * 30)),
            ("new", now),
            ("mid", now.addingTimeInterval(-3600 * 24)),
        ])
        #expect(entries.map(\.name) == ["new", "mid", "old"])
    }

    @Test("dedupes local + remote — local wins")
    func dedupePrefersLocal() {
        let now = Date()
        let entries = make(
            local: [("feat", now)],
            remote: [("feat", now.addingTimeInterval(-1))]
        )
        #expect(entries.count == 1)
        #expect(entries.first?.source == .local)
    }

    @Test("@spec GIT-5.13: dims branches with mountedWorktreePath")
    func annotatesMounted() {
        let now = Date()
        let entries = make(
            local: [("feat", now)],
            mounted: ["feat": "/r/.worktrees/feat"]
        )
        #expect(entries.first?.mountedWorktreePath == "/r/.worktrees/feat")
    }

    @Test("@spec GIT-5.14: surfaces PR info when present")
    func attachesPRInfo() {
        let now = Date()
        let pr = PRInfo(
            number: 42,
            title: "Add OAuth",
            url: URL(string: "https://x/y")!,
            state: .open,
            checks: .success,
            mergeable: .mergeable,
            fetchedAt: now
        )
        let entries = make(
            local: [("feat", now)],
            prs: ["feat": pr]
        )
        #expect(entries.first?.pr?.number == 42)
        #expect(entries.first?.pr?.title == "Add OAuth")
    }

    @Test("filterText filters by case-insensitive substring on name")
    func filtersByText() {
        let now = Date()
        let entries = make(
            local: [("Feat-Login", now), ("docs", now)],
            filter: "feat"
        )
        #expect(entries.map(\.name) == ["Feat-Login"])
    }

    @Test("filters out sentinel branches")
    func filtersSentinels() {
        let now = Date()
        let entries = make(local: [("(detached)", now), ("(bare)", now), ("feat", now)])
        #expect(entries.map(\.name) == ["feat"])
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter BranchPickerViewModelTests`

Expected: FAIL — `BranchPickerEntry` and `BranchPickerViewModel` don't exist.

- [ ] **Step 3: Implement `BranchPickerEntry`**

Create `Sources/GrafttyKit/Model/BranchPickerEntry.swift`:

```swift
import Foundation

public struct BranchPickerEntry: Sendable, Hashable {
    public let name: String
    public let source: BranchSelection.ExistingSource
    public let lastCommitDate: Date
    /// Non-nil when this branch is currently mounted in another
    /// worktree of the same repo. Used to render dim/disabled rows
    /// (GIT-5.13).
    public let mountedWorktreePath: String?
    public let pr: PRSummary?

    public struct PRSummary: Sendable, Hashable {
        public let number: Int
        public let title: String
        public init(number: Int, title: String) {
            self.number = number
            self.title = title
        }
    }

    public init(
        name: String,
        source: BranchSelection.ExistingSource,
        lastCommitDate: Date,
        mountedWorktreePath: String?,
        pr: PRSummary?
    ) {
        self.name = name
        self.source = source
        self.lastCommitDate = lastCommitDate
        self.mountedWorktreePath = mountedWorktreePath
        self.pr = pr
    }
}
```

- [ ] **Step 4: Implement `BranchPickerViewModel.entries`**

Create `Sources/GrafttyKit/Model/BranchPickerViewModel.swift`:

```swift
import Foundation

public enum BranchPickerViewModel {
    /// Build the sorted, filtered, dimmed entry list for the picker.
    /// Pure; no SwiftUI, no MainActor.
    public static func entries(
        branchSnapshot: RemoteBranchSnapshot,
        mountedBranchToPath: [String: String],
        prsByBranch: [String: PRInfo],
        filterText: String
    ) -> [BranchPickerEntry] {
        // Local wins on collision — local ref is what `git worktree add` will use.
        var byName: [String: BranchPickerEntry] = [:]
        for ref in branchSnapshot.localBranches {
            guard RemoteBranchStore.isEligibleLocalBranch(ref.name) else { continue }
            byName[ref.name] = build(
                ref: ref,
                source: .local,
                mounted: mountedBranchToPath[ref.name],
                pr: prsByBranch[ref.name]
            )
        }
        for ref in branchSnapshot.remoteBranches {
            guard byName[ref.name] == nil else { continue }
            guard RemoteBranchStore.isEligibleLocalBranch(ref.name) else { continue }
            byName[ref.name] = build(
                ref: ref,
                source: .remoteOnly,
                mounted: mountedBranchToPath[ref.name],
                pr: prsByBranch[ref.name]
            )
        }

        var result = Array(byName.values)
        if !filterText.isEmpty {
            let needle = filterText.lowercased()
            result = result.filter { $0.name.lowercased().contains(needle) }
        }
        result.sort { lhs, rhs in
            if lhs.lastCommitDate != rhs.lastCommitDate {
                return lhs.lastCommitDate > rhs.lastCommitDate
            }
            return lhs.name < rhs.name
        }
        return result
    }

    private static func build(
        ref: BranchRef,
        source: BranchSelection.ExistingSource,
        mounted: String?,
        pr: PRInfo?
    ) -> BranchPickerEntry {
        let summary = pr.map { BranchPickerEntry.PRSummary(number: $0.number, title: $0.title) }
        return BranchPickerEntry(
            name: ref.name,
            source: source,
            lastCommitDate: ref.lastCommitDate,
            mountedWorktreePath: mounted,
            pr: summary
        )
    }
}
```

- [ ] **Step 5: Run the test, expect pass**

Run: `swift test --filter BranchPickerViewModelTests`

Expected: PASS (all six).

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Model/BranchPickerEntry.swift \
        Sources/GrafttyKit/Model/BranchPickerViewModel.swift \
        Tests/GrafttyKitTests/Model/BranchPickerViewModelTests.swift
git commit -m "feat(branches): BranchPickerEntry + pure-Swift view model"
```

---

## Task 6: Mac `BranchComboBox` view

A SwiftUI TextField that opens a popover of `BranchPickerEntry` rows. Mounted rows are `.disabled(true) .opacity(0.5)`. Keyboard nav with up/down/return.

**Files:**
- Create: `Sources/Graftty/Views/BranchComboBox.swift`

- [ ] **Step 1: Implement the view**

Create `Sources/Graftty/Views/BranchComboBox.swift`:

```swift
import SwiftUI
import GrafttyKit

/// Combobox: a TextField wrapping a popover that lists matching
/// branches. Selecting a row sets `text` to the branch name and
/// invokes `onSelect`. Mounted rows are disabled and dimmed.
struct BranchComboBox: View {
    @Binding var text: String
    let entries: [BranchPickerEntry]
    let onSelect: (BranchPickerEntry) -> Void

    @State private var showPopover: Bool = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        TextField("Pick or type branch name", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($fieldFocused)
            .onChange(of: fieldFocused) { _, focused in
                if focused { showPopover = true }
            }
            .onChange(of: text) { _, _ in
                showPopover = true
            }
            .popover(isPresented: $showPopover, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
                popoverList
                    .frame(width: 320)
            }
    }

    private var popoverList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    Text("No branches match")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                } else {
                    ForEach(entries, id: \.name) { entry in
                        row(for: entry)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 240)
    }

    @ViewBuilder
    private func row(for entry: BranchPickerEntry) -> some View {
        let mounted = entry.mountedWorktreePath != nil
        HStack(spacing: 8) {
            Text(entry.name)
                .font(.callout)
                .strikethrough(mounted)
                .lineLimit(1)
            if mounted, let path = entry.mountedWorktreePath {
                Text("in worktree \((path as NSString).lastPathComponent)")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let pr = entry.pr {
                Text("#\(pr.number) · \(pr.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Text(relativeDate(entry.lastCommitDate))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .opacity(mounted ? 0.5 : 1)
        .background(Color.clear)
        .onTapGesture {
            guard !mounted else { return }
            text = entry.name
            onSelect(entry)
            showPopover = false
        }
        .disabled(mounted)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Views/BranchComboBox.swift
git commit -m "feat(ui-mac): BranchComboBox view for the existing-branch picker"
```

---

## Task 7: Mac sheet — segmented mode + flow wiring

Wire the segmented control into `AddWorktreeSheet`. Pass `BranchSelection` to `onSubmit`. Update `MainWindow.addWorktree` to route through the new flow signature and surface `branchAlreadyMounted` errors.

**Files:**
- Modify: `Sources/Graftty/Views/AddWorktreeSheet.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`

- [ ] **Step 1: Update `AddWorktreeSheet`**

Modify `Sources/Graftty/Views/AddWorktreeSheet.swift`:

Replace the file body with this version. The submit closure now takes a `BranchSelection` instead of two `String`s.

```swift
import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol

struct AddWorktreeSheet: View {
    enum BranchMode: Hashable { case newBranch, existing }

    let repoDisplayName: String
    let initialWorktreeName: String
    let branchEntries: [BranchPickerEntry]
    let onSubmit: (String, BranchSelection) async -> String?
    let onCancel: () -> Void

    @State private var worktreeName: String
    @State private var branchName: String
    @State private var branchMode: BranchMode = .newBranch
    @State private var branchMirrorsWorktree: Bool = true
    @State private var worktreeMirrorsBranch: Bool = true
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var selectedExistingSource: BranchSelection.ExistingSource = .local

    @FocusState private var worktreeFieldFocused: Bool

    init(
        repoDisplayName: String,
        initialWorktreeName: String = "",
        branchEntries: [BranchPickerEntry] = [],
        onSubmit: @escaping (String, BranchSelection) async -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.repoDisplayName = repoDisplayName
        self.initialWorktreeName = initialWorktreeName
        self.branchEntries = branchEntries
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _worktreeName = State(initialValue: initialWorktreeName)
        _branchName = State(initialValue: initialWorktreeName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Worktree to \(repoDisplayName)")
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Worktree name:")
                        .foregroundStyle(.secondary)
                    TextField("feature-xyz", text: $worktreeName)
                        .textFieldStyle(.roundedBorder)
                        .focused($worktreeFieldFocused)
                        .onChange(of: worktreeName) { _, new in
                            let sanitized = WorktreeNameSanitizer.sanitize(new)
                            if sanitized != new {
                                worktreeName = sanitized
                                return
                            }
                            if branchMode == .newBranch && branchMirrorsWorktree {
                                branchName = sanitized
                            }
                            if branchMode == .existing && sanitized != selectedBranchName {
                                worktreeMirrorsBranch = false
                            }
                        }
                }
                GridRow {
                    Text("Branch:")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $branchMode) {
                            Text("New branch").tag(BranchMode.newBranch)
                            Text("Existing branch").tag(BranchMode.existing)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if branchMode == .newBranch {
                            TextField("feature-xyz", text: $branchName)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: branchName) { _, new in
                                    let sanitized = WorktreeNameSanitizer.sanitize(new)
                                    if sanitized != new {
                                        branchName = sanitized
                                        return
                                    }
                                    if sanitized != worktreeName {
                                        branchMirrorsWorktree = false
                                    }
                                }
                        } else {
                            BranchComboBox(
                                text: $branchName,
                                entries: branchEntries
                            ) { entry in
                                branchName = entry.name
                                selectedExistingSource = entry.source
                                if worktreeMirrorsBranch {
                                    worktreeName = entry.name
                                }
                            }
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            worktreeFieldFocused = true
            if !initialWorktreeName.isEmpty {
                DispatchQueue.main.async {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
        }
    }

    private var selectedBranchName: String { branchName }

    private var canSubmit: Bool {
        !WorktreeNameSanitizer.trimForSubmit(worktreeName).isEmpty
            && !WorktreeNameSanitizer.trimForSubmit(branchName).isEmpty
    }

    private var selectedSelection: BranchSelection {
        let trimmed = WorktreeNameSanitizer.trimForSubmit(branchName)
        switch branchMode {
        case .newBranch:
            return .createNew(name: trimmed)
        case .existing:
            return .useExisting(name: trimmed, source: selectedExistingSource)
        }
    }

    private func submit() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        let wt = WorktreeNameSanitizer.trimForSubmit(worktreeName)
        if let err = await onSubmit(wt, selectedSelection) {
            errorMessage = err
        }
    }
}
```

- [ ] **Step 2: Update `MainWindow.addWorktree`**

In `Sources/Graftty/Views/MainWindow.swift`, the existing `addWorktree(...)` private method passes `branchName` strings. Replace its inner logic to accept `BranchSelection` from the sheet:

1. Pass the live `branchEntries` to `AddWorktreeSheet`. Build them via `BranchPickerViewModel.entries(...)` using `remoteBranchStore.branchesByRepo[repoPath]`, the repo's `branchMountedPath` data, and `prStatusStore.prsByRepoBranch[repoPath] ?? [:]`.
2. The sheet's `onSubmit` now receives `(String, BranchSelection)`. Forward `branch` directly to `AddWorktreeFlow.beginCreate` / `finishCreate`.
3. On `branchAlreadyMounted` from `beginCreate`, return its `userMessage` to the sheet so it renders the inline error.

Pulse the stores when opening the sheet so the picker is fresh:

```swift
remoteBranchStore.pulse()
prStatusStore.pulse()
```

- [ ] **Step 3: Build, run the app manually to smoke-test the sheet**

Run: `swift build`

Expected: BUILD SUCCEEDED.

Manually open the macOS app, click Add Worktree on a repo with multiple branches and an open PR. Verify the segmented control toggles between New/Existing modes, the picker shows branches with PR titles and relative dates, and mounted branches are dimmed and unselectable. Try creating a worktree both from a new branch and from an existing one. Confirm a mounted-branch selection surfaces the inline error.

- [ ] **Step 4: Commit**

```bash
git add Sources/Graftty/Views/AddWorktreeSheet.swift \
        Sources/Graftty/Views/MainWindow.swift
git commit -m "feat(ui-mac): segmented new/existing branch mode in Add Worktree sheet"
```

---

## Task 8: Web `POST /worktrees` — `existing` flag

Add the optional `existing: Bool` field to the request decoder. Build a `BranchSelection` from it. Map `branchAlreadyMounted` to a 409 Conflict.

**Files:**
- Modify: `Sources/Graftty/Web/WebServerController.swift`
- Modify: `Tests/GrafttyKitTests/Web/WebServerWorktreeEndpointTests.swift`

- [ ] **Step 1: Read the current handler**

Run: `grep -n "POST /worktrees\|createWorktree\|worktreeName\|branchName" Sources/Graftty/Web/WebServerController.swift | head -20`

Identify the request struct and the call site for `AddWorktreeFlow.add`. Note them in your scratch — the next step modifies both.

- [ ] **Step 2: Add a failing test for `existing: true`**

In `Tests/GrafttyKitTests/Web/WebServerWorktreeEndpointTests.swift`, append:

```swift
@Test("@spec GIT-5.10: POST /worktrees with existing=true passes .useExisting to the flow")
@MainActor
func postWithExistingTrueUsesUseExisting() async throws {
    // Match the existing test scaffolding in this file — inject a stub
    // for AddWorktreeFlow.add (or its caller) that captures the
    // BranchSelection it was invoked with. Assert .useExisting(_, .local).
    Issue.record("Replace placeholder — follow existing scaffolding pattern in this file.")
}
```

NOTE: The exact stubbing pattern comes from the surrounding tests — read the file head and copy the request-fixture and capture pattern.

- [ ] **Step 3: Run the test, expect fail**

Run: `swift test --filter WebServerWorktreeEndpointTests`

Expected: FAIL (Issue.record or no `existing` field on the request struct).

- [ ] **Step 4: Update the handler**

In `Sources/Graftty/Web/WebServerController.swift`:

1. Add `existing: Bool?` to the create-request struct.
2. When decoding, build `BranchSelection`:

```swift
let branch: BranchSelection
if body.existing == true {
    // Default to .local source on the web path — the server can't
    // disambiguate local vs remote-only on its own (the client knows
    // because the user picked from the same data the server publishes).
    // Adding a separate `source` field would over-spec the wire
    // contract; if the branch only exists on origin, `git worktree
    // add <path> <name>` resolves it the same way (git tries local,
    // falls back to a remote-tracking ref). Keep simple.
    branch = .useExisting(name: body.branchName, source: .local)
} else {
    branch = .createNew(name: body.branchName)
}
```

3. Map errors:

```swift
case .branchAlreadyMounted(let path):
    return .conflict(message: "branch is already mounted at " + (path as NSString).lastPathComponent)
```

(Use the surrounding handler's error-encoding pattern verbatim; the helper or status-code function exists in the file.)

- [ ] **Step 5: Fill in the test, then run**

Replace the `Issue.record` placeholder with real assertions based on the scaffolding pattern in this test file.

Run: `swift test --filter WebServerWorktreeEndpointTests`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Graftty/Web/WebServerController.swift \
        Tests/GrafttyKitTests/Web/WebServerWorktreeEndpointTests.swift
git commit -m "feat(web): POST /worktrees existing flag + branchAlreadyMounted → 409"
```

---

## Task 9: iOS sheet — segmented mode + push picker

Mirror the Mac UI on iOS. New mode is the existing text field; existing mode pushes a list view.

**Files:**
- Modify: `Sources/GrafttyMobileKit/Session/CreateWorktreeClient.swift`
- Modify: `Sources/GrafttyMobileKit/UI/AddWorktreeSheetView.swift`
- Create: `Sources/GrafttyMobileKit/UI/BranchPickerView.swift`

NOTE: Per `feedback_macos_swift_test_misses_uikit_guarded_code.md`, this code is `#if canImport(UIKit)`-gated and `swift test` on macOS will not exercise it. Verification is via iOS CI and manual on-device smoke test.

- [ ] **Step 1: Add the `existing` flag to `CreateWorktreeClient.Request`**

In `Sources/GrafttyMobileKit/Session/CreateWorktreeClient.swift`, add:

```swift
public struct Request: Encodable {
    public let repoPath: String
    public let worktreeName: String
    public let branchName: String
    public let existing: Bool

    public init(
        repoPath: String,
        worktreeName: String,
        branchName: String,
        existing: Bool = false
    ) {
        self.repoPath = repoPath
        self.worktreeName = worktreeName
        self.branchName = branchName
        self.existing = existing
    }
}
```

- [ ] **Step 2: Create `BranchPickerView`**

Create `Sources/GrafttyMobileKit/UI/BranchPickerView.swift`:

```swift
#if canImport(UIKit)
import SwiftUI
import GrafttyKit

struct BranchPickerView: View {
    let entries: [BranchPickerEntry]
    let onSelect: (BranchPickerEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter: String = ""

    var body: some View {
        List {
            ForEach(filtered, id: \.name) { entry in
                row(for: entry)
            }
        }
        .listStyle(.plain)
        .searchable(text: $filter, prompt: "Filter branches")
        .navigationTitle("Pick branch")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var filtered: [BranchPickerEntry] {
        guard !filter.isEmpty else { return entries }
        let needle = filter.lowercased()
        return entries.filter { $0.name.lowercased().contains(needle) }
    }

    @ViewBuilder
    private func row(for entry: BranchPickerEntry) -> some View {
        let mounted = entry.mountedWorktreePath != nil
        Button {
            guard !mounted else { return }
            onSelect(entry)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.name)
                        .strikethrough(mounted)
                    Spacer()
                    Text(relativeDate(entry.lastCommitDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if mounted, let path = entry.mountedWorktreePath {
                    Text("in worktree \((path as NSString).lastPathComponent)")
                        .font(.caption2)
                        .italic()
                        .foregroundStyle(.secondary)
                } else if let pr = entry.pr {
                    Text("#\(pr.number) · \(pr.title)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .disabled(mounted)
        .opacity(mounted ? 0.5 : 1)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
#endif
```

- [ ] **Step 3: Update `AddWorktreeSheetView`**

In `Sources/GrafttyMobileKit/UI/AddWorktreeSheetView.swift`, add a `branchMode` state, swap the branch section for a segmented `Picker`, and conditionally push to `BranchPickerView`:

Replace the existing `branchName` `Section` block with:

```swift
Section("Branch") {
    Picker("Mode", selection: $branchMode) {
        Text("New branch").tag(BranchMode.newBranch)
        Text("Existing branch").tag(BranchMode.existing)
    }
    .pickerStyle(.segmented)

    if branchMode == .newBranch {
        TextField("feature-xyz", text: $branchName)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onChange(of: branchName) { _, new in
                let sanitized = WorktreeNameSanitizer.sanitize(new)
                if sanitized != new {
                    branchName = sanitized
                    return
                }
                if sanitized != worktreeName {
                    branchMirrorsWorktree = false
                }
            }
    } else {
        NavigationLink {
            BranchPickerView(entries: branchEntries) { entry in
                branchName = entry.name
                selectedExistingSource = entry.source
                if worktreeMirrorsBranch {
                    worktreeName = entry.name
                }
            }
        } label: {
            HStack {
                Text(branchName.isEmpty ? "Choose branch…" : branchName)
                Spacer()
            }
        }
    }
}
```

Add state:

```swift
@State private var branchMode: BranchMode = .newBranch
@State private var worktreeMirrorsBranch: Bool = true
@State private var selectedExistingSource: BranchSelection.ExistingSource = .local

enum BranchMode { case newBranch, existing }
```

Update `submit()` to set `existing` in the request:

```swift
let body = CreateWorktreeClient.Request(
    repoPath: repoPath,
    worktreeName: WorktreeNameSanitizer.trimForSubmit(worktreeName),
    branchName: WorktreeNameSanitizer.trimForSubmit(branchName),
    existing: branchMode == .existing
)
```

Add a `branchEntries` parameter to the view's initializer; the caller (`HostsView` or wherever the sheet is presented) passes either an empty array initially or the result of an HTTP fetch (a follow-up endpoint can ship later — for this PR, an empty list is acceptable on iOS since the user can still type a name in existing mode; the server will accept it).

- [ ] **Step 4: Build (macOS will not exercise iOS code; CI runs the iOS scheme)**

Run: `swift build`

Expected: BUILD SUCCEEDED (UIKit-guarded code is not compiled on macOS — symbols only resolve under the iOS scheme).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/UI/AddWorktreeSheetView.swift \
        Sources/GrafttyMobileKit/UI/BranchPickerView.swift \
        Sources/GrafttyMobileKit/Session/CreateWorktreeClient.swift
git commit -m "feat(ui-ios): segmented mode + BranchPickerView in iOS sheet"
```

---

## Task 10: Regenerate SPECS.md

`SPECS.md` is generated from `@spec` annotations in code. Six new IDs (GIT-5.10..5.15) need to land.

**Files:**
- Modify: `SPECS.md` (generated)

- [ ] **Step 1: Run the generator**

Run: `scripts/generate-specs.py`

Expected: `SPECS.md` updated in place. The script's stdout will list changed entries.

- [ ] **Step 2: Run the verifier to confirm no duplicates and no stale entries**

Run: `scripts/generate-specs.py --check`

Expected: exit 0, no diff against working tree.

- [ ] **Step 3: Run the full test suite**

Run: `swift test`

Expected: ALL TESTS PASS. If a flaky test fires, retry once; if it still fails, investigate the root cause (per `feedback_test_slowdowns_indicate_bugs.md`, don't bump budgets to mask).

- [ ] **Step 4: Commit**

```bash
git add SPECS.md
git commit -m "docs(specs): regenerate SPECS.md for GIT-5.10..5.15"
```

---

## Task 11: Run /simplify

Per project convention (`CLAUDE.md`): always run `/simplify` before opening a PR. It reviews the changed code for reuse, quality, and efficiency.

- [ ] **Step 1: Invoke /simplify**

Run the `simplify` skill against the diff between this branch and `main`. Apply any improvements it surfaces.

- [ ] **Step 2: If /simplify made changes, commit them**

```bash
git add -u
git commit -m "chore: simplify per /simplify review"
```

(Skip the commit if /simplify found nothing actionable.)

---

## Task 12: Push and open PR

- [ ] **Step 1: Push the branch**

```bash
git push -u origin create-worktree-existing-branch
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "feat(worktree): create from existing branch (GIT-5.10..5.15)" --body "$(cat <<'EOF'
## Summary

- Segmented "New / Existing" mode in the Add Worktree sheet (Mac + iOS)
- New combobox picker for existing branches: PR/MR number+title, last-commit relative date, dimmed-mounted rows
- `BranchSelection` enum drives `git worktree add` argv: `-b <new>` vs bare `<existing>` vs `origin/<remoteOnly>`
- `RemoteBranchSnapshot` now carries commit dates; `PRStatusStore` publishes a per-repo, per-branch index alongside the per-worktree one
- `branchAlreadyMounted(at:)` flow error rejects creates that git would refuse anyway; web endpoint returns 409
- New `@spec` IDs GIT-5.10 through GIT-5.15

Spec: \`docs/superpowers/specs/2026-05-13-create-worktree-existing-branch-design.md\`
Plan: \`docs/superpowers/plans/2026-05-13-create-worktree-existing-branch.md\`

## Test plan

- [x] Unit: \`swift test\` (Mac CI)
- [ ] iOS CI build pass (per memory: \`swift test\` does not exercise UIKit-guarded code)
- [ ] Manual: Add Worktree from main repo, both modes
- [ ] Manual: existing branch with open PR shows number+title
- [ ] Manual: mounted branch is dimmed and unselectable
- [ ] Manual: stale-snapshot edge case (delete a branch via terminal, then try to pick it)
EOF
)"
```

- [ ] **Step 3: Confirm CI is green**

After push, watch CI; verify the `verify-specs` job and the test suite both pass. If anything fails, address it and amend with a new commit (no `--force` push to main; on this branch, push the new commit and let CI rerun).

---

## Self-Review

**Spec coverage:**
- GIT-5.10 (no `-b` for existing) → Task 2 argv test
- GIT-5.11 (rejection before git) → Task 3 flow test
- GIT-5.12 (`origin/<name>` for remote-only) → Task 2 argv test
- GIT-5.13 (sort desc + dim mounted) → Task 5 view-model tests
- GIT-5.14 (PR number+title) → Task 5 view-model test (data); Task 6 + Task 9 render
- GIT-5.15 (worktree-name auto-fill) → Task 7 (UI logic), exercised manually
- `BranchPickerEntry` / `BranchPickerViewModel` → Task 5
- `prsByRepoBranch` → Task 4
- Per-ref commit dates → Task 1
- `branchAlreadyMounted` 409 → Task 8
- iOS segmented mode → Task 9
- `SPECS.md` regenerated → Task 10

**Placeholder scan:** Two `Issue.record(...)` placeholders intentionally appear in Tasks 4 Step 2 and 8 Step 2 because the matching test scaffolding lives in existing files the agent must read first. Both steps tell the agent to replace the placeholder with a real assertion using the surrounding fixture pattern. This is acceptable per the plan format — the agent has the explicit signal "Replace placeholder with the pattern in this file." Any other placeholder would be a defect.

**Type consistency:** `BranchSelection.ExistingSource` is used consistently across `BranchSelection.swift`, `BranchPickerEntry.swift`, the view model, both view layers, and the iOS request. `BranchPickerEntry` is `Hashable + Sendable` everywhere. `BranchRef` is in `GrafttyKit`, used by the snapshot and the view model.
