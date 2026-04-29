# Remote Branch Gated PR/MR Polling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate GitHub/GitLab PR/MR polling on cheap local detection of `origin/<branch>` so unpushed worktrees do not call host CLIs, while pushed worktrees start polling without a tab switch.

**Architecture:** Add a focused `RemoteBranchStore` that owns local `refs/remotes/origin/*` scanning and publishes repo-keyed remote branch sets. `PRStatusStore` receives an injected pushed-branch gate and skips unpushed branches. App wiring connects origin-ref watcher events, branch-change events, repo lifecycle cleanup, and 10-second local scans to the new store.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI Observation (`@Observable`), existing `PollingTickerLike`, existing async `GitRunner`/`CLIRunner`, existing `PRStatusStore` and `WorktreeStatsStore` patterns.

---

## File Structure

Create:

- `Sources/GrafttyKit/Git/RemoteBranchStore.swift`
  - Owns repo-keyed remote branch snapshots.
  - Runs local-only `git for-each-ref`.
  - Deduplicates concurrent scans by repo.
  - Emits change callbacks for app-level cache cleanup and PR tick pulses.

- `Tests/GrafttyKitTests/Git/RemoteBranchStoreTests.swift`
  - Tests parsing, refresh publication, failure preservation, in-flight dedupe, ticker behavior, and `clear(repoPath:)`.

- `Tests/GrafttyKitTests/PRStatus/PRStatusStoreRemoteBranchGateTests.swift`
  - Tests that refresh/tick skip unpushed branches and start when the gate becomes true.

Modify:

- `Sources/GrafttyKit/PRStatus/PRStatusStore.swift`
  - Inject pushed-branch gate.
  - Apply gate in manual refresh, branch-change refresh, and background tick candidate selection.

- `Sources/Graftty/GrafttyApp.swift`
  - Add `RemoteBranchStore` to `AppServices`.
  - Wire `PRStatusStore` to `RemoteBranchStore.hasRemote`.
  - Start the 10-second remote-branch scan ticker.
  - Set `RemoteBranchStore.onChange` to pulse PR polling on branch appearance and clear PR caches on branch disappearance.
  - Pass `RemoteBranchStore` into `WorktreeMonitorBridge`.
  - Update origin-ref and branch-change handlers to refresh the remote-branch index before PR polling decisions.
  - Pass `RemoteBranchStore` through relocate flow.

- `Sources/Graftty/Views/MainWindow.swift`
  - Accept `remoteBranchStore`.
  - Clear repo-keyed remote branch cache on remove-repo.
  - Refresh remote branch cache after add-repo.

- `Sources/GrafttyKit/Git/RepoTeardown.swift`
  - Clear repo-keyed remote branch cache as part of shared repo teardown.

- `SPECS.md`
  - Add EARS requirements for 10-second local ref scanning, PR/MR gate behavior, branch appearance, and branch disappearance.

Existing uncommitted files to account for before implementation:

- `Sources/Graftty/GrafttyApp.swift`
- `Tests/GrafttyTests/WorktreeMonitorBridgeTests.swift`

Those changes are the earlier push-then-create follow-up fix. Before executing this plan, either commit them separately or fold them into Task 5 so the origin-ref bridge ends in one coherent shape.

---

### Task 1: RemoteBranchStore Core

**Files:**

- Create: `Sources/GrafttyKit/Git/RemoteBranchStore.swift`
- Create: `Tests/GrafttyKitTests/Git/RemoteBranchStoreTests.swift`

- [ ] **Step 1: Write parser and publication tests**

Add tests like:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("RemoteBranchStore")
struct RemoteBranchStoreTests {
    @Test func parseStripsOriginPrefixPreservesSlashesAndSkipsHead() {
        let refs = """
        origin/HEAD
        origin/main
        origin/feature/foo
        upstream/ignored

        """

        #expect(RemoteBranchStore.parseRefsForTesting(refs) == [
            "main",
            "feature/foo",
        ])
    }

    @MainActor
    @Test func refreshPublishesBranchesAndReportsHasRemote() async throws {
        let lister = RecordingRemoteBranchLister(results: [
            "/repo": .success(["main", "feature/foo"])
        ])
        let store = RemoteBranchStore(list: lister.list)

        store.refresh(repoPath: "/repo")

        try await waitUntil(timeout: 1.0) {
            store.hasRemote(repoPath: "/repo", branch: "feature/foo")
        }
        #expect(!store.hasRemote(repoPath: "/repo", branch: "missing"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RemoteBranchStoreTests`

Expected: compile failure because `RemoteBranchStore` does not exist.

- [ ] **Step 3: Implement minimal RemoteBranchStore**

Create `Sources/GrafttyKit/Git/RemoteBranchStore.swift`:

```swift
import Foundation
import Observation
import os

@MainActor
@Observable
public final class RemoteBranchStore {
    public private(set) var branchesByRepo: [String: Set<String>] = [:]

    public typealias ListFunction = @Sendable (_ repoPath: String) async throws -> Set<String>

    @ObservationIgnored public var onChange: (@MainActor (_ repoPath: String, _ old: Set<String>, _ new: Set<String>) -> Void)?
    @ObservationIgnored private let list: ListFunction
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.btucker.graftty", category: "RemoteBranchStore")

    public init(list: @escaping ListFunction = RemoteBranchStore.defaultList) {
        self.list = list
    }

    public func hasRemote(repoPath: String, branch: String) -> Bool {
        guard Self.isEligibleLocalBranch(branch) else { return false }
        return branchesByRepo[repoPath]?.contains(branch) == true
    }

    public func clear(repoPath: String) {
        branchesByRepo.removeValue(forKey: repoPath)
        inFlight.remove(repoPath)
    }

    public func refresh(repoPath: String, completion: (@MainActor () -> Void)? = nil) {
        guard !inFlight.contains(repoPath) else { return }
        inFlight.insert(repoPath)
        let list = self.list
        Task { [weak self] in
            do {
                let branches = try await list(repoPath)
                self?.apply(repoPath: repoPath, branches: branches)
            } catch {
                self?.logger.info("remote branch scan failed for \(repoPath): \(String(describing: error))")
                self?.inFlight.remove(repoPath)
            }
            completion?()
        }
    }

    private func apply(repoPath: String, branches: Set<String>) {
        let old = branchesByRepo[repoPath] ?? []
        inFlight.remove(repoPath)
        guard old != branches else { return }
        branchesByRepo[repoPath] = branches
        onChange?(repoPath, old, branches)
    }

    nonisolated static func isEligibleLocalBranch(_ branch: String) -> Bool {
        if branch.hasPrefix("(") && branch.hasSuffix(")") { return false }
        return !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func parseRefs(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { raw in
            let ref = String(raw)
            guard ref.hasPrefix("origin/") else { return nil }
            let branch = String(ref.dropFirst("origin/".count))
            guard branch != "HEAD" else { return nil }
            return branch
        })
    }

    nonisolated static let defaultList: ListFunction = { repoPath in
        let output = try await GitRunner.run(
            args: ["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin"],
            at: repoPath
        )
        return parseRefs(output)
    }

    static func parseRefsForTesting(_ output: String) -> Set<String> {
        parseRefs(output)
    }
}
```

- [ ] **Step 4: Add failure preservation, clear, and dedupe tests**

Add tests:

```swift
@MainActor
@Test func failedRefreshPreservesPreviousSnapshot() async throws {
    let lister = RecordingRemoteBranchLister(results: [
        "/repo": .success(["main"]),
    ])
    let store = RemoteBranchStore(list: lister.list)
    store.refresh(repoPath: "/repo")
    try await waitUntil(timeout: 1.0) {
        store.hasRemote(repoPath: "/repo", branch: "main")
    }

    await lister.set(result: .failure(TestError.boom), for: "/repo")
    store.refresh(repoPath: "/repo")
    try await Task.sleep(for: .milliseconds(100))

    #expect(store.hasRemote(repoPath: "/repo", branch: "main"))
}

@MainActor
@Test func clearDropsSnapshot() async throws {
    let store = RemoteBranchStore(list: { _ in ["main"] })
    store.refresh(repoPath: "/repo")
    try await waitUntil(timeout: 1.0) {
        store.hasRemote(repoPath: "/repo", branch: "main")
    }

    store.clear(repoPath: "/repo")

    #expect(!store.hasRemote(repoPath: "/repo", branch: "main"))
}
```

- [ ] **Step 5: Run RemoteBranchStore tests**

Run: `swift test --filter RemoteBranchStoreTests`

Expected: all `RemoteBranchStoreTests` pass.

- [ ] **Step 6: Commit Task 1**

```bash
git add Sources/GrafttyKit/Git/RemoteBranchStore.swift Tests/GrafttyKitTests/Git/RemoteBranchStoreTests.swift
git commit -m "feat(git): track local remote branches"
```

---

### Task 2: RemoteBranchStore Polling

**Files:**

- Modify: `Sources/GrafttyKit/Git/RemoteBranchStore.swift`
- Modify: `Tests/GrafttyKitTests/Git/RemoteBranchStoreTests.swift`

- [ ] **Step 1: Write ticker test**

Add:

```swift
@MainActor
@Test func startRefreshesEachTrackedRepoOnTickerFire() async throws {
    let lister = RecordingRemoteBranchLister(results: [
        "/a": .success(["main"]),
        "/b": .success(["feature"]),
    ])
    let ticker = CapturingTicker()
    let store = RemoteBranchStore(list: lister.list)
    let repos = [
        RepoEntry(path: "/a", displayName: "a", worktrees: []),
        RepoEntry(path: "/b", displayName: "b", worktrees: []),
    ]

    store.start(ticker: ticker, getRepos: { repos })
    await ticker.fire()

    try await waitUntil(timeout: 1.0) {
        store.hasRemote(repoPath: "/a", branch: "main")
            && store.hasRemote(repoPath: "/b", branch: "feature")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RemoteBranchStoreTests`

Expected: compile failure because `start(ticker:getRepos:)` does not exist.

- [ ] **Step 3: Implement ticker support**

Add to `RemoteBranchStore`:

```swift
@ObservationIgnored private var ticker: PollingTickerLike?
@ObservationIgnored private var getRepos: @MainActor () -> [RepoEntry] = { [] }

public func start(
    ticker: PollingTickerLike,
    getRepos: @escaping @MainActor () -> [RepoEntry]
) {
    stop()
    self.ticker = ticker
    self.getRepos = getRepos
    ticker.start { [weak self] in
        guard let self else { return }
        for repo in getRepos() {
            self.refresh(repoPath: repo.path)
        }
    }
}

public func stop() {
    ticker?.stop()
    ticker = nil
}

public func pulse() {
    ticker?.pulse()
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter RemoteBranchStoreTests`

Expected: all `RemoteBranchStoreTests` pass.

- [ ] **Step 5: Commit Task 2**

```bash
git add Sources/GrafttyKit/Git/RemoteBranchStore.swift Tests/GrafttyKitTests/Git/RemoteBranchStoreTests.swift
git commit -m "feat(git): poll local remote branch refs"
```

---

### Task 3: PRStatusStore Remote-Branch Gate

**Files:**

- Modify: `Sources/GrafttyKit/PRStatus/PRStatusStore.swift`
- Create: `Tests/GrafttyKitTests/PRStatus/PRStatusStoreRemoteBranchGateTests.swift`

- [ ] **Step 1: Write refresh gate test**

Create `Tests/GrafttyKitTests/PRStatus/PRStatusStoreRemoteBranchGateTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("PRStatusStore remote branch gate")
struct PRStatusStoreRemoteBranchGateTests {
    @MainActor
    @Test func refreshSkipsUnpushedBranch() async throws {
        let fetcher = CountingPRFetcher(response: nil)
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in Self.origin },
            isPushedBranch: { _, _ in false }
        )

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feature")
        try await Task.sleep(for: .milliseconds(100))

        #expect(await fetcher.invocations == 0)
        #expect(store.infos["/wt"] == nil)
        #expect(!store.absent.contains("/wt"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PRStatusStoreRemoteBranchGateTests`

Expected: compile failure because the `PRStatusStore` initializer has no `isPushedBranch` parameter.

- [ ] **Step 3: Add gate injection**

Modify `PRStatusStore`:

```swift
@ObservationIgnored private let isPushedBranch: @MainActor (_ repoPath: String, _ branch: String) -> Bool

public init(
    executor: CLIExecutor = CLIRunner(),
    fetcherFor: ((HostingProvider) -> PRFetcher?)? = nil,
    detectHost: (@Sendable (String) async throws -> HostingOrigin?)? = nil,
    isPushedBranch: @escaping @MainActor (_ repoPath: String, _ branch: String) -> Bool = { _, _ in true }
) {
    self.executor = executor
    self.isPushedBranch = isPushedBranch
    ...
}
```

Apply the gate in `refresh`:

```swift
guard Self.isFetchableBranch(branch) else { return }
guard isPushedBranch(repoPath, branch) else { return }
```

Apply the same gate in `tick()` before cadence checks:

```swift
if !Self.isFetchableBranch(wt.branch) { continue }
if !isPushedBranch(repo.path, wt.branch) { continue }
```

- [ ] **Step 4: Add tick and transition tests**

Add tests:

```swift
@MainActor
@Test func tickSkipsUnpushedBranch() async throws {
    let fetcher = CountingPRFetcher(response: nil)
    let ticker = CapturingTicker()
    let store = PRStatusStore(
        executor: FakeCLIExecutor(),
        fetcherFor: { _ in fetcher },
        detectHost: { _ in Self.origin },
        isPushedBranch: { _, _ in false }
    )
    let repo = RepoEntry(
        path: "/repo",
        displayName: "repo",
        worktrees: [WorktreeEntry(path: "/repo/wt", branch: "feature")]
    )

    store.start(ticker: ticker, getRepos: { [repo] })
    await ticker.fire()

    try await Task.sleep(for: .milliseconds(100))
    #expect(await fetcher.invocations == 0)
}

@MainActor
@Test func refreshStartsWhenGateTurnsTrue() async throws {
    var pushed = false
    let fetcher = CountingPRFetcher(response: Self.pr(number: 42))
    let store = PRStatusStore(
        executor: FakeCLIExecutor(),
        fetcherFor: { _ in fetcher },
        detectHost: { _ in Self.origin },
        isPushedBranch: { _, _ in pushed }
    )

    store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feature")
    try await Task.sleep(for: .milliseconds(100))
    #expect(await fetcher.invocations == 0)

    pushed = true
    store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feature")

    try await waitUntil(timeout: 1.0) {
        await fetcher.invocations == 1
    }
    #expect(store.infos["/wt"]?.number == 42)
}
```

- [ ] **Step 5: Run PRStatusStore gate tests**

Run: `swift test --filter PRStatusStoreRemoteBranchGateTests`

Expected: all gate tests pass.

- [ ] **Step 6: Run existing PRStatusStore tests**

Run: `swift test --filter PRStatusStore`

Expected: all existing PRStatusStore tests still pass. The default gate `{ true }` should preserve existing behavior where tests do not inject a gate.

- [ ] **Step 7: Commit Task 3**

```bash
git add Sources/GrafttyKit/PRStatus/PRStatusStore.swift Tests/GrafttyKitTests/PRStatus/PRStatusStoreRemoteBranchGateTests.swift
git commit -m "feat(pr): gate polling on pushed branches"
```

---

### Task 4: AppServices Startup Wiring

**Files:**

- Modify: `Sources/Graftty/GrafttyApp.swift`

- [ ] **Step 1: Add RemoteBranchStore to AppServices**

Modify `AppServices`:

```swift
let remoteBranchStore: RemoteBranchStore
let prStatusStore: PRStatusStore
```

In `init(socketPath:)`, construct the remote store before PR store:

```swift
let remoteBranchStore = RemoteBranchStore()
self.remoteBranchStore = remoteBranchStore
self.prStatusStore = PRStatusStore(
    isPushedBranch: { repoPath, branch in
        remoteBranchStore.hasRemote(repoPath: repoPath, branch: branch)
    }
)
```

- [ ] **Step 2: Wire onChange in startup**

After `let binding = $appState` exists in `startup()`, set:

```swift
let remoteBranchStore = services.remoteBranchStore
let prStatusStore = services.prStatusStore
remoteBranchStore.onChange = { repoPath, old, new in
    guard let repo = binding.wrappedValue.repos.first(where: { $0.path == repoPath }) else { return }

    for wt in repo.worktrees where wt.state.hasOnDiskWorktree {
        if old.contains(wt.branch) && !new.contains(wt.branch) {
            prStatusStore.clear(worktreePath: wt.path)
        }
    }

    if !new.subtracting(old).isEmpty {
        prStatusStore.pulse()
    }
}
```

- [ ] **Step 3: Start the 10-second local-ref ticker before PR ticker**

In `startup()`, before `services.prStatusStore.start(...)`:

```swift
let remoteBranchTicker = PollingTicker(
    interval: .seconds(10),
    pauseWhenInactive: { false }
)
services.remoteBranchStore.start(
    ticker: remoteBranchTicker,
    getRepos: { binding.wrappedValue.repos }
)
for repo in binding.wrappedValue.repos {
    services.remoteBranchStore.refresh(repoPath: repo.path)
}
```

- [ ] **Step 4: Build and run focused tests**

Run: `swift test --filter PRStatusStoreRemoteBranchGateTests --filter RemoteBranchStoreTests`

Expected: build succeeds and both suites pass.

- [ ] **Step 5: Commit Task 4**

```bash
git add Sources/Graftty/GrafttyApp.swift
git commit -m "feat(app): wire remote branch polling"
```

---

### Task 5: WorktreeMonitorBridge Event Flow

**Files:**

- Modify: `Sources/Graftty/GrafttyApp.swift`
- Modify or keep: `Tests/GrafttyTests/WorktreeMonitorBridgeTests.swift`

- [ ] **Step 1: Update WorktreeMonitorBridge initializer**

Add a stored property:

```swift
let remoteBranchStore: RemoteBranchStore
private let originRefPRFollowUpDelays: [Duration]
```

Update `init`:

```swift
init(
    appState: Binding<AppState>,
    statsStore: WorktreeStatsStore,
    prStatusStore: PRStatusStore,
    remoteBranchStore: RemoteBranchStore,
    originRefPRFollowUpDelays: [Duration] = [.seconds(1), .seconds(5)]
) {
    self.appState = appState
    self.statsStore = statsStore
    self.prStatusStore = prStatusStore
    self.remoteBranchStore = remoteBranchStore
    self.originRefPRFollowUpDelays = originRefPRFollowUpDelays
}
```

Update the construction site in `startup()`:

```swift
let bridge = WorktreeMonitorBridge(
    appState: $appState,
    statsStore: services.statsStore,
    prStatusStore: services.prStatusStore,
    remoteBranchStore: services.remoteBranchStore
)
```

- [ ] **Step 2: Write/update origin-ref test**

Use or adapt `Tests/GrafttyTests/WorktreeMonitorBridgeTests.swift` so the test verifies:

- first PR lookup returns `nil`
- origin-ref handler refreshes local remote branches
- delayed follow-up runs only after `origin/feature` is known locally
- second PR lookup returns PR #42 without selecting the worktree

Expected fixture shape:

```swift
let remoteBranchStore = RemoteBranchStore(list: { _ in ["feature"] })
let bridge = WorktreeMonitorBridge(
    appState: binding,
    statsStore: statsStore,
    prStatusStore: prStore,
    remoteBranchStore: remoteBranchStore,
    originRefPRFollowUpDelays: [.milliseconds(50)]
)
```

- [ ] **Step 3: Run test to verify current code fails or does not compile**

Run: `swift test --filter WorktreeMonitorBridgeTests`

Expected: failure/compile error until bridge accepts and uses `RemoteBranchStore`.

- [ ] **Step 4: Update origin-ref handler**

Change `worktreeMonitorDidDetectOriginRefChange` to:

1. Refresh stats for all non-stale worktrees as today.
2. Call `remoteBranchStore.refresh(repoPath:)`.
3. In the refresh completion, run immediate PR refreshes only for worktrees whose branch now has a local origin ref.
4. Schedule delayed follow-ups that re-check eligibility at execution time.

Implementation helper:

```swift
private func refreshPushedPRs(repoPath: String) {
    guard let repo = appState.wrappedValue.repos.first(where: { $0.path == repoPath }) else { return }
    for wt in repo.worktrees where wt.state.hasOnDiskWorktree {
        guard remoteBranchStore.hasRemote(repoPath: repoPath, branch: wt.branch) else { continue }
        prStatusStore.refresh(worktreePath: wt.path, repoPath: repoPath, branch: wt.branch)
    }
}

private func scheduleOriginRefPRFollowUps(repoPath: String) {
    for delay in originRefPRFollowUpDelays {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            refreshPushedPRs(repoPath: repoPath)
        }
    }
}
```

Then in the origin-ref event:

```swift
remoteBranchStore.refresh(repoPath: repoPath) { [weak self] in
    self?.refreshPushedPRs(repoPath: repoPath)
    self?.scheduleOriginRefPRFollowUps(repoPath: repoPath)
}
```

- [ ] **Step 5: Update branch-change handler**

After rediscovering the branch and updating `appState`, clear stale PR info immediately, then refresh local remote branches before asking for PR status:

```swift
prStore.clear(worktreePath: worktreePath)
remoteBranchStore.refresh(repoPath: repoPath) {
    prStore.refresh(worktreePath: worktreePath, repoPath: repoPath, branch: match.branch)
}
```

Do not call `branchDidChange` here unless its behavior is adjusted to avoid a duplicate clear/fetch.

- [ ] **Step 6: Run bridge tests**

Run: `swift test --filter WorktreeMonitorBridgeTests`

Expected: all bridge tests pass.

- [ ] **Step 7: Run app-target smoke build via tests**

Run: `swift test --filter WorktreeMonitorBridgeTests --filter PRStatusStoreRemoteBranchGateTests`

Expected: app target compiles and both suites pass.

- [ ] **Step 8: Commit Task 5**

```bash
git add Sources/Graftty/GrafttyApp.swift Tests/GrafttyTests/WorktreeMonitorBridgeTests.swift
git commit -m "feat(pr): refresh status when pushed refs appear"
```

---

### Task 6: Repo Lifecycle Integration

**Files:**

- Modify: `Sources/GrafttyKit/Git/RepoTeardown.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`

- [ ] **Step 1: Update RepoTeardown**

Change signature:

```swift
public static func stopWatchersAndClearCaches(
    repo: RepoEntry,
    worktreeMonitor: WorktreeMonitor,
    statsStore: WorktreeStatsStore,
    prStatusStore: PRStatusStore,
    remoteBranchStore: RemoteBranchStore? = nil
)
```

At the end:

```swift
remoteBranchStore?.clear(repoPath: repo.path)
```

- [ ] **Step 2: Pass RemoteBranchStore through relocate flow**

Update `resolveRepoLocations` and `relocateRepo` signatures in `GrafttyApp.swift` to accept `remoteBranchStore: RemoteBranchStore`.

Pass it into `RepoTeardown.stopWatchersAndClearCaches(...)`.

After `worktreeMonitor.installRepoWatchers(repo:)` in `relocateRepo`, refresh the new repo path:

```swift
remoteBranchStore.refresh(repoPath: newRepoPath)
```

- [ ] **Step 3: Pass RemoteBranchStore into MainWindow**

Add `let remoteBranchStore: RemoteBranchStore` to `MainWindow`.

Update `GrafttyApp.body` construction:

```swift
remoteBranchStore: services.remoteBranchStore,
```

In `removeRepoWithConfirmation`, pass it into `RepoTeardown.stopWatchersAndClearCaches(...)`.

In `addRepoFromPath`, after `appState.addRepo(repo)`, call:

```swift
remoteBranchStore.refresh(repoPath: repoPath)
```

- [ ] **Step 4: Run compile-focused tests**

Run: `swift test --filter WorktreeMonitorBridgeTests`

Expected: compile succeeds and bridge tests pass.

- [ ] **Step 5: Commit Task 6**

```bash
git add Sources/GrafttyKit/Git/RepoTeardown.swift Sources/Graftty/GrafttyApp.swift Sources/Graftty/Views/MainWindow.swift
git commit -m "feat(git): clear remote branch cache on repo lifecycle"
```

---

### Task 7: SPECS.md Requirements

**Files:**

- Modify: `SPECS.md`

- [ ] **Step 1: Add EARS requirements**

Under `### 4.2 Filesystem Monitoring`, append requirements after `GIT-2.7`:

```markdown
**GIT-2.8** While a repository is in the sidebar, the application shall scan local `refs/remotes/origin/*` every 10 seconds without contacting the network, maintaining a repo-scoped set of locally-known remote branch names. The scan shall use local git ref metadata only; it shall not replace the repo-level fetch cadence that discovers branches created from another clone.

**GIT-2.9** When the origin-ref watcher from `GIT-2.5` observes a remote-tracking ref movement, the application shall refresh the repo's local remote-branch set before deciding which worktrees should receive PR/MR polling.
```

Under PR/MR status requirements, add or update entries. If there is no nearby section, place them under Worktree Discovery & Monitoring / Change Handling:

```markdown
**GIT-3.17** When a worktree's current branch lacks a local `origin/<branch>` ref, the application shall skip GitHub/GitLab PR/MR host polling for that worktree and shall not mark the worktree as "absent PR" merely because the branch has not been pushed.

**GIT-3.18** When a local `origin/<branch>` ref appears for a non-stale worktree's current branch, the application shall begin PR/MR polling for that worktree on the pushed-branch cadence without requiring the user to select the worktree.

**GIT-3.19** When a local `origin/<branch>` ref disappears for a non-stale worktree's current branch, the application shall clear cached PR/MR status for that worktree so stale PR badges do not remain attached to an unpushed or deleted remote branch.
```

- [ ] **Step 2: Run diff check**

Run: `git diff --check`

Expected: no whitespace errors.

- [ ] **Step 3: Commit Task 7**

```bash
git add SPECS.md
git commit -m "docs(specs): require remote-branch-gated PR polling"
```

---

### Task 8: Full Verification

**Files:**

- No code changes expected unless failures reveal issues.

- [ ] **Step 1: Run focused suites**

Run:

```bash
swift test --filter RemoteBranchStoreTests
swift test --filter PRStatusStoreRemoteBranchGateTests
swift test --filter PRStatusStore
swift test --filter WorktreeMonitorBridgeTests
```

Expected: all pass.

- [ ] **Step 2: Run broader relevant suites**

Run:

```bash
swift test --filter WorktreeStatsStore
swift test --filter WorktreeMonitor
swift test --filter RepoRelocator
```

Expected: all pass.

- [ ] **Step 3: Run final diff hygiene**

Run:

```bash
git diff --check
git status --short
```

Expected: `git diff --check` has no output. `git status --short` shows only intentional committed state or no uncommitted changes.

- [ ] **Step 4: Manual smoke checklist**

Run Graftty locally and verify:

1. Create/open a worktree on a local-only branch. Confirm no PR badge appears and logs do not show repeated `gh`/`glab` calls for that branch.
2. Push the branch from the worktree. Confirm the origin-ref watcher path starts PR polling without selecting another tab.
3. Create a PR after push. Confirm the 1s/5s follow-up catches it without tab selection.
4. Delete/prune the remote branch locally. Confirm the PR badge clears.
5. Switch the worktree to another branch with an existing `origin/<branch>`. Confirm PR polling starts after the branch-change path.

- [ ] **Step 5: Final commit if verification required fixups**

If verification required any fixes:

```bash
git add <fixed files>
git commit -m "fix(pr): stabilize remote branch gated polling"
```

If no fixes were needed, do not create an empty commit.
