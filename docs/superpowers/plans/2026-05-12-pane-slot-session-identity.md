# Pane Slot And Session Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split stable pane layout identity from live pane session identity so fresh shells cannot inherit stale zmx sessions, team hooks, or delivery targets.

**Architecture:** `PaneSlotID` identifies the durable UI/layout slot stored in `SplitTree`. `PaneSessionID` identifies the current live terminal session for that slot and is the only source for zmx session names, hook routing, shell PID lookup, and message delivery. Stop/reopen preserves pane slots but clears/recreates pane sessions; app quit/relaunch preserves pane sessions for worktrees that are still marked running.

**Tech Stack:** Swift 5.10, Swift Testing, AppKit, GhosttyKit, existing `SplitTree`, `WorktreeEntry`, `TerminalManager`, `ZmxLauncher`, team presence and idle-delivery pipeline.

---

## File Structure

- Rename `Sources/GrafttyKit/Model/TerminalID.swift` to `Sources/GrafttyKit/Model/PaneSlotID.swift`
  - Defines `PaneSlotID`, the durable layout/sidebar/focus ID.
  - Temporary compatibility typealias is allowed during the first task only; final state should not use `TerminalID`.
- Create `Sources/GrafttyKit/Model/PaneSessionID.swift`
  - Defines `PaneSessionID`, a fresh UUID-backed live session ID.
  - Includes migration initializer from an old slot UUID so existing running zmx sessions survive the upgrade.
- Modify `Sources/GrafttyKit/Model/SplitTree.swift`
  - Replace `TerminalID` with `PaneSlotID` throughout.
  - Keep semantics unchanged: split tree owns slots, not sessions.
- Modify `Sources/GrafttyKit/Model/WorktreeEntry.swift`
  - Add `paneSessions: [PaneSlotID: PaneSessionID]`.
  - Add helpers to assign, lookup, migrate, clear, and move sessions.
  - Clear sessions on Stop; preserve sessions while the app remains running.
- Modify `Sources/GrafttyKit/Zmx/ZmxLauncher.swift`
  - Add `sessionName(for sessionID: PaneSessionID)`.
  - Remove or deprecate runtime uses of `sessionName(for paneID: UUID)`.
- Modify `Sources/GrafttyKit/Zmx/ZmxSpawnConfiguration.swift`
  - Accept `PaneSessionID`, not pane slot UUID.
- Modify `Sources/Graftty/Terminal/TerminalManager.swift`
  - Surfaces stay keyed by `PaneSlotID`.
  - Add per-surface runtime mapping `PaneSlotID -> PaneSessionID`.
  - Resolve, kill, lookup shell PID, and reverse-map zmx sessions through `PaneSessionID`.
- Modify `Sources/Graftty/GrafttyApp.swift`
  - Ensure pane sessions are created for every fresh open/split.
  - Preserve pane sessions for rehydrated running worktrees.
  - Clear pane sessions on Stop.
  - Route team hooks and inbox delivery by live session name, not slot ID.
  - Remove the process-tree delivery workaround added in `TeamDeliveryPaneResolver`.
- Modify `Sources/Graftty/AddWorktreeFlow.swift`
  - Create a session for the first slot before spawning its surface.
- Modify `Sources/Graftty/Views/MainWindow.swift`
  - Open, stop, stale recovery, and selection flows use `PaneSlotID` for UI and `PaneSessionID` for zmx.
- Modify `Sources/Graftty/AppZmxWriter.swift`
  - Still accepts zmx session names, but TerminalManager reverse lookup must use current session mappings.
- Modify web/sidebar helpers that display zmx session names:
  - `Sources/Graftty/Views/SidebarView.swift`
  - `Sources/Graftty/GrafttyApp.swift` session snapshot helpers
  - Any `PaneInfo` construction that currently derives zmx name from slot UUID.
- Delete after replacement:
  - `Sources/GrafttyKit/Teams/TeamDeliveryPaneResolver.swift`
  - `Tests/GrafttyKitTests/Teams/TeamDeliveryPaneResolverTests.swift`
- Update tests:
  - `Tests/GrafttyKitTests/Model/SplitTreeTests.swift`
  - `Tests/GrafttyKitTests/Model/WorktreeEntryTests.swift`
  - `Tests/GrafttyKitTests/Zmx/ZmxLauncherTests.swift`
  - `Tests/GrafttyKitTests/Zmx/ZmxSpawnConfigurationTests.swift`
  - `Tests/GrafttyTests/Terminal/TerminalManagerMetadataTests.swift`
  - `Tests/GrafttyTests/Specs/IdleDeliveryTests.swift`
  - `Tests/GrafttyKitTests/Teams/ZmxNudgeSenderTests.swift`
  - Any remaining tests found by `rg -n "TerminalID|sessionName\\(for:" Tests Sources`.

## Task 1: Rename Layout Identity To `PaneSlotID`

**Files:**
- Move: `Sources/GrafttyKit/Model/TerminalID.swift` -> `Sources/GrafttyKit/Model/PaneSlotID.swift`
- Modify: `Sources/GrafttyKit/Model/SplitTree.swift`
- Modify: all direct `TerminalID` references in `Sources/` and `Tests/`

- [ ] **Step 1: Write a failing compile-time rename test**

Add or update a small model test in `Tests/GrafttyKitTests/Model/SplitTreeTests.swift`:

```swift
@Test func splitTreeStoresPaneSlotIDs() {
    let slot = PaneSlotID()
    let tree = SplitTree(root: .leaf(slot))
    #expect(tree.allLeaves == [slot])
}
```

- [ ] **Step 2: Run test to verify RED**

Run:

```bash
swift test --filter splitTreeStoresPaneSlotIDs
```

Expected: FAIL because `PaneSlotID` does not exist yet.

- [ ] **Step 3: Introduce `PaneSlotID`**

Rename the file and struct:

```swift
public struct PaneSlotID: Hashable, Codable, Identifiable, Sendable {
    public let id: UUID

    public init() {
        self.id = UUID()
    }

    public init(id: UUID) {
        self.id = id
    }
}
```

During this task only, add this compatibility alias at the bottom of `PaneSlotID.swift` so the repo can be renamed incrementally:

```swift
@available(*, deprecated, renamed: "PaneSlotID")
public typealias TerminalID = PaneSlotID
```

- [ ] **Step 4: Rename core model references**

Update `SplitTree`, `WorktreeEntry`, and `WorktreeEntry+FirstPane` to use `PaneSlotID` in public APIs and stored properties.

Run:

```bash
rg -n "TerminalID" Sources/GrafttyKit/Model Sources/Graftty/Model
```

Expected: no remaining hits except historical comments if intentionally left for migration notes.

- [ ] **Step 5: Run focused model tests**

Run:

```bash
swift test --filter SplitTreeTests
swift test --filter WorktreeEntryTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Model Tests/GrafttyKitTests/Model
git commit -m "refactor(model): rename pane layout id to PaneSlotID"
```

## Task 2: Add `PaneSessionID` And Worktree Session State

**Files:**
- Create: `Sources/GrafttyKit/Model/PaneSessionID.swift`
- Modify: `Sources/GrafttyKit/Model/WorktreeEntry.swift`
- Modify: `Tests/GrafttyKitTests/Model/WorktreeEntryTests.swift`

- [ ] **Step 1: Write failing tests for slot/session lifecycle**

Add tests:

```swift
@Test func ensurePaneSessionsAssignsFreshSessionsForSlots() {
    var entry = WorktreeEntry(path: "/repo/wt", branch: "feature")
    let slot = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    entry.splitTree = SplitTree(root: .leaf(slot))

    let first = entry.ensurePaneSession(for: slot)
    let second = entry.ensurePaneSession(for: slot)

    #expect(first == second)
    #expect(entry.paneSessions[slot] == first)
}

@Test func prepareForStopClearsPaneSessionsButPreservesSlots() {
    var entry = WorktreeEntry(path: "/repo/wt", branch: "feature")
    let slot = PaneSlotID()
    entry.splitTree = SplitTree(root: .leaf(slot))
    let session = entry.ensurePaneSession(for: slot)

    entry.prepareForStop()

    #expect(entry.splitTree.allLeaves == [slot])
    #expect(entry.paneSessions.isEmpty)
    #expect(entry.ensurePaneSession(for: slot) != session)
}

@Test func runningWorktreeWithoutPaneSessionsMigratesFromOldSlotIDs() {
    var entry = WorktreeEntry(path: "/repo/wt", branch: "feature", state: .running)
    let slot = PaneSlotID(id: UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000000")!)
    entry.splitTree = SplitTree(root: .leaf(slot))

    entry.ensurePaneSessionsForRunningRestore()

    #expect(entry.paneSessions[slot]?.id == slot.id)
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter WorktreeEntryTests
```

Expected: FAIL because `PaneSessionID`, `paneSessions`, and helper methods do not exist.

- [ ] **Step 3: Implement `PaneSessionID`**

Create:

```swift
public struct PaneSessionID: Hashable, Codable, Identifiable, Sendable {
    public let id: UUID

    public init() {
        self.id = UUID()
    }

    public init(id: UUID) {
        self.id = id
    }

    public static func migratedFromLegacySlot(_ slot: PaneSlotID) -> PaneSessionID {
        PaneSessionID(id: slot.id)
    }
}
```

- [ ] **Step 4: Add `paneSessions` to `WorktreeEntry`**

Add stored property:

```swift
public var paneSessions: [PaneSlotID: PaneSessionID]
```

Add Codable defaulting:

```swift
self.paneSessions = try container.decodeIfPresent(
    [PaneSlotID: PaneSessionID].self,
    forKey: .paneSessions
) ?? [:]
```

Add coding key `paneSessions`.

- [ ] **Step 5: Add helper methods**

Add:

```swift
@discardableResult
public mutating func ensurePaneSession(for slot: PaneSlotID) -> PaneSessionID {
    if let existing = paneSessions[slot] { return existing }
    let session = PaneSessionID()
    paneSessions[slot] = session
    return session
}

public mutating func ensurePaneSessionsForRunningRestore() {
    for slot in splitTree.allLeaves where paneSessions[slot] == nil {
        paneSessions[slot] = .migratedFromLegacySlot(slot)
    }
}

public mutating func clearPaneSession(for slot: PaneSlotID) {
    paneSessions.removeValue(forKey: slot)
}

public mutating func clearAllPaneSessions() {
    paneSessions.removeAll()
}
```

Update `prepareForStop`, `prepareForResurrection`, and `prepareForDismissal` to clear `paneSessions`.

- [ ] **Step 6: Run tests and verify GREEN**

Run:

```bash
swift test --filter WorktreeEntryTests
swift test --filter AppStateTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Model Tests/GrafttyKitTests/Model
git commit -m "feat(model): track live pane session ids separately from slots"
```

## Task 3: Derive zmx Session Names From `PaneSessionID`

**Files:**
- Modify: `Sources/GrafttyKit/Zmx/ZmxLauncher.swift`
- Modify: `Sources/GrafttyKit/Zmx/ZmxSpawnConfiguration.swift`
- Modify: `Tests/GrafttyKitTests/Zmx/ZmxLauncherTests.swift`
- Modify: `Tests/GrafttyKitTests/Zmx/ZmxSpawnConfigurationTests.swift`
- Modify: `Tests/GrafttyKitTests/Teams/ZmxNudgeSenderTests.swift`
- Modify: `Tests/GrafttyKitTests/Teams/IdleDeliveryEndToEndTests.swift`

- [ ] **Step 1: Write failing zmx naming tests**

Add:

```swift
@Test func sessionNameUsesPaneSessionID() {
    let sessionID = PaneSessionID(id: UUID(uuidString: "01234567-89AB-CDEF-FEDC-BA9876543210")!)
    #expect(ZmxLauncher.sessionName(for: sessionID) == "graftty-01234567")
}
```

Update `ZmxSpawnConfigurationTests` so `make(...)` passes `paneSessionID:` instead of `paneID:`.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter ZmxLauncherTests
swift test --filter ZmxSpawnConfigurationTests
```

Expected: FAIL on missing `sessionName(for: PaneSessionID)` and old `paneID:` parameter.

- [ ] **Step 3: Update `ZmxLauncher`**

Add:

```swift
public static func sessionName(for sessionID: PaneSessionID) -> String {
    let hex = sessionID.id.uuidString
        .replacingOccurrences(of: "-", with: "")
        .lowercased()
    return "graftty-\(hex.prefix(8))"
}

public func sessionName(for sessionID: PaneSessionID) -> String {
    ZmxLauncher.sessionName(for: sessionID)
}
```

Leave UUID overload temporarily for integration tests that create arbitrary sessions. Mark it internal/test-only later if possible.

- [ ] **Step 4: Update `ZmxSpawnConfiguration`**

Change signature:

```swift
public static func make(
    launcher: ZmxLauncher,
    paneSessionID: PaneSessionID,
    worktreePath: String,
    ...
) -> ZmxSpawnConfiguration
```

Set:

```swift
let sessionName = launcher.sessionName(for: paneSessionID)
```

- [ ] **Step 5: Update nudge tests to separate slot and session**

`ZmxNudgeSender` currently accepts a UUID and derives a session. Decide here whether its public API should become:

```swift
public protocol NudgeSender: Sendable {
    func send(sessionName: String, message: String, messageIDs: [String]) async
}
```

Recommendation: make `IdleDeliveryService` session-name based. This prevents the service from ever confusing slot IDs with session IDs.

- [ ] **Step 6: Run focused zmx/team tests**

Run:

```bash
swift test --filter ZmxLauncherTests
swift test --filter ZmxSpawnConfigurationTests
swift test --filter ZmxNudgeSenderTests
swift test --filter IdleDeliveryEndToEndTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Zmx Sources/GrafttyKit/Teams Tests/GrafttyKitTests/Zmx Tests/GrafttyKitTests/Teams
git commit -m "refactor(zmx): derive sessions from PaneSessionID"
```

## Task 4: Thread Sessions Through `TerminalManager`

**Files:**
- Modify: `Sources/Graftty/Terminal/TerminalManager.swift`
- Modify: `Sources/Graftty/AppZmxWriter.swift`
- Modify: `Tests/GrafttyTests/Terminal/TerminalManagerMetadataTests.swift`
- Add tests as needed under `Tests/GrafttyTests/Terminal/`

- [ ] **Step 1: Write failing tests for reverse lookup by current session**

Add a test seam if needed so this can be tested without real Ghostty surfaces. The required behavior:

```swift
@Test func currentSessionNameChangesWhenSlotGetsNewSession() {
    let slot = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let first = PaneSessionID(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!)
    let second = PaneSessionID(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!)
    let manager = TerminalManager(socketPath: "/tmp/graftty.sock")

    manager.recordPaneSessionForTesting(slot: slot, sessionID: first)
    #expect(manager.paneID(forSessionName: "graftty-aaaaaaaa") == slot.id)

    manager.recordPaneSessionForTesting(slot: slot, sessionID: second)
    #expect(manager.paneID(forSessionName: "graftty-aaaaaaaa") == nil)
    #expect(manager.paneID(forSessionName: "graftty-bbbbbbbb") == slot.id)
}
```

- [ ] **Step 2: Run test and verify RED**

Run:

```bash
swift test --filter TerminalManagerMetadataTests
```

Expected: FAIL because TerminalManager derives session names from slot IDs.

- [ ] **Step 3: Add session mapping to `TerminalManager`**

Add:

```swift
private var paneSessions: [PaneSlotID: PaneSessionID] = [:]
```

Update create methods:

```swift
func createSurface(
    terminalID: PaneSlotID,
    paneSessionID: PaneSessionID,
    worktreePath: String,
    extraInitialInput: String? = nil
) -> SurfaceHandle?
```

and:

```swift
func createSurfaces(
    for splitTree: SplitTree,
    paneSessions: [PaneSlotID: PaneSessionID],
    worktreePath: String
) -> [PaneSlotID: SurfaceHandle]
```

Use `paneSessionID` in `resolveZmxSpawnConfiguration`.

- [ ] **Step 4: Update reverse lookup and kill paths**

Change:

```swift
func handle(forSessionName sessionName: String) -> SurfaceHandle?
func paneID(forSessionName sessionName: String) -> UUID?
func lookupShellPID(for id: PaneSlotID) -> pid_t?
private func killZmxSession(for terminalID: PaneSlotID)
```

All should use `paneSessions[slot]` and `ZmxLauncher.sessionName(for: sessionID)`.

Important ordering: `destroySurface` must call `paneClosed` and `killZmxSession` before removing the slot's `paneSessions` entry, or it must capture the session name first.

- [ ] **Step 5: Update pane-close callback to include session name**

Change callback to:

```swift
var paneClosed: ((PaneSlotID, String?) -> Void)?
```

This lets team presence cleanup delete records for the exact old session even after the slot receives a new session later.

- [ ] **Step 6: Run focused terminal tests**

Run:

```bash
swift test --filter TerminalManagerMetadataTests
swift test --filter HostManagedZmxBackendTests
swift test --filter NativePtySessionTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/Graftty/Terminal Sources/Graftty/AppZmxWriter.swift Tests/GrafttyTests/Terminal
git commit -m "refactor(terminal): track live pane sessions in TerminalManager"
```

## Task 5: Update App Lifecycle Flows

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Modify: `Sources/Graftty/AddWorktreeFlow.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`
- Modify: `Sources/Graftty/Views/SidebarView.swift`
- Modify: `Tests/GrafttyTests/Specs/AttnPaneControlTests.swift`
- Modify: `Tests/GrafttyKitTests/Notification/PaneInfoFormatTests.swift` if session output changes

- [ ] **Step 1: Write failing lifecycle regression tests**

Add tests that cover the actual bug:

```swift
@Test func stopThenReopenKeepsSlotButCreatesNewSession() {
    var entry = WorktreeEntry(path: "/repo/wt", branch: "feature", state: .running)
    let slot = PaneSlotID(id: UUID(uuidString: "11111111-0000-0000-0000-000000000000")!)
    entry.splitTree = SplitTree(root: .leaf(slot))
    let oldSession = entry.ensurePaneSession(for: slot)

    entry.prepareForStop()
    entry.state = .running
    let newSession = entry.ensurePaneSession(for: slot)

    #expect(entry.splitTree.allLeaves == [slot])
    #expect(newSession != oldSession)
}
```

Add a routing regression at the app/manager level:

```swift
@Test func lateHookForOldSessionDoesNotResolveAfterReopen() {
    // Build using the TerminalManager metadata seam from Task 4:
    // slot -> old session resolves, slot -> new session no longer resolves old name.
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter stopThenReopenKeepsSlotButCreatesNewSession
swift test --filter lateHookForOldSessionDoesNotResolveAfterReopen
```

Expected: FAIL before app lifecycle is updated.

- [ ] **Step 3: Update open/restoration flow**

In `restoreRunningWorktrees()`:

```swift
if wt.state == .running {
    appState.repos[repoIdx].worktrees[wtIdx].ensurePaneSessionsForRunningRestore()
    let sessions = appState.repos[repoIdx].worktrees[wtIdx].paneSessions
    terminalManager.createSurfaces(for: splitTree, paneSessions: sessions, worktreePath: wt.path)
}
```

Rationale: old persisted running worktrees without `paneSessions` should migrate to session IDs equal to their old slot IDs so existing daemons reattach once.

- [ ] **Step 4: Update closed-worktree open flow**

In `MainWindow` and `AddWorktreeFlow`, before calling `createSurfaces`:

```swift
for slot in splitTree.allLeaves {
    appState.repos[repoIdx].worktrees[wtIdx].ensurePaneSession(for: slot)
}
let sessions = appState.repos[repoIdx].worktrees[wtIdx].paneSessions
terminalManager.createSurfaces(for: splitTree, paneSessions: sessions, worktreePath: path)
```

For a newly created first slot, create both slot and session before spawning.

- [ ] **Step 5: Update split pane flow**

When splitting:

```swift
let newSlot = PaneSlotID()
let newSession = PaneSessionID()
worktree.paneSessions[newSlot] = newSession
terminalManager.createSurface(
    terminalID: newSlot,
    paneSessionID: newSession,
    worktreePath: wt.path,
    extraInitialInput: extraInitialInput
)
```

- [ ] **Step 6: Update close pane and move pane flow**

Close:

```swift
terminalManager.destroySurface(terminalID: targetSlot)
worktree.clearPaneSession(for: targetSlot)
worktree.splitTree = worktree.splitTree.removing(targetSlot)
```

Move pane between worktrees:

- Move the slot as before.
- Move its `PaneSessionID` from source worktree to target worktree.
- Do not regenerate the session; moving a live pane should preserve the running process.

- [ ] **Step 7: Update Stop and Restart ZMX flows**

For each affected worktree:

1. Capture leaves.
2. Destroy surfaces for leaves.
3. Call `prepareForStop()`, which clears sessions but preserves slots.

Do not clear split tree.

- [ ] **Step 8: Update session display helpers**

Any UI/API that displays a zmx session name for a pane must use:

```swift
worktree.paneSessions[slot].map(ZmxLauncher.sessionName(for:))
```

If a running worktree has a slot without a session, treat it as "surface not ready" rather than deriving from slot ID.

- [ ] **Step 9: Run lifecycle and pane-control tests**

Run:

```bash
swift test --filter WorktreeEntryTests
swift test --filter AttnPaneControlTests
swift test --filter PaneInfoFormatTests
swift test --filter ZmxRestartConfirmationTests
```

Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift Sources/Graftty/AddWorktreeFlow.swift Sources/Graftty/Views Tests/GrafttyTests Tests/GrafttyKitTests
git commit -m "feat(panes): create fresh sessions for reopened pane slots"
```

## Task 6: Restore Team Delivery To Identity-Based Routing

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Modify: `Sources/GrafttyKit/Teams/IdleDeliveryService.swift`
- Delete: `Sources/GrafttyKit/Teams/TeamDeliveryPaneResolver.swift`
- Delete: `Tests/GrafttyKitTests/Teams/TeamDeliveryPaneResolverTests.swift`
- Modify: `Tests/GrafttyTests/Specs/IdleDeliveryTests.swift`
- Modify: `Tests/GrafttyKitTests/Teams/IdleDeliveryEndToEndTests.swift`

- [ ] **Step 1: Write failing team routing regression**

Add a test for the real failure mode:

```swift
@Test func lateStopForOldSessionDoesNotDeliverToFreshSessionInSameSlot() async throws {
    let oldSessionName = "graftty-aaaaaaaa"
    let newSessionName = "graftty-bbbbbbbb"

    // Simulate TerminalManager reverse lookup after reopen:
    // oldSessionName -> nil, newSessionName -> slot.
    // A Stop callback carrying oldSessionName must not call IdleDeliveryService.
}
```

The test can be a pure helper if needed. Prefer extracting a small routing helper over building a full app.

- [ ] **Step 2: Run test and verify RED**

Run:

```bash
swift test --filter lateStopForOldSessionDoesNotDeliverToFreshSessionInSameSlot
```

Expected: FAIL before `paneID(forSessionName:)` uses live session mapping or before helper exists.

- [ ] **Step 3: Change `IdleDeliveryService` to session-name targets**

Update protocol:

```swift
public protocol NudgeSender: Sendable {
    func send(sessionName: String, message: String, messageIDs: [String]) async
}
```

Update service:

```swift
public func onStop(team: String, worktree: String, sessionNames: [String]) async
public func onMessageArrival(team: String, worktree: String, sessionNames: [String]) async
```

The service should not know about slot IDs or pane IDs.

- [ ] **Step 4: Update production sender**

`ZmxNudgeSender.send(sessionName:message:messageIDs:)` should write exactly that session name through `ZmxWriter`.

- [ ] **Step 5: Update app hook callbacks**

For Stop:

```swift
guard runtime == TeamHookRuntime.codex.rawValue else { return }
guard let paneSessionName else { return }
guard tm.handle(forSessionName: paneSessionName) != nil else { return }
Task { await service.onStop(team: team, worktree: worktree, sessionNames: [paneSessionName]) }
```

The `handle(forSessionName:)` check is the live identity gate. Old session names do not resolve after reopen.

- [ ] **Step 6: Update inbox-arrival resolution**

Replace the current process-tree resolver with simple live-session resolution:

```swift
let codexSessionsIn: @Sendable (String) -> [String] = { [tm] worktreePath in
    MainActor.assumeIsolated {
        let records = (try? presenceStorage.listAll()) ?? []
        return records.compactMap { record in
            guard record.worktree == worktreePath,
                  record.runtime == .codex,
                  let sessionName = record.paneSessionName,
                  tm.handle(forSessionName: sessionName) != nil else {
                return nil
            }
            return sessionName
        }
    }
}
```

No process tree inspection. No `ps`. No matching command names.

- [ ] **Step 7: Delete process-tree workaround**

Delete:

```bash
rm Sources/GrafttyKit/Teams/TeamDeliveryPaneResolver.swift
rm Tests/GrafttyKitTests/Teams/TeamDeliveryPaneResolverTests.swift
```

Use `apply_patch` if doing this manually.

- [ ] **Step 8: Run team tests**

Run:

```bash
swift test --filter IdleDeliveryServiceTests
swift test --filter IdleDeliveryEndToEndTests
swift test --filter ZmxNudgeSenderTests
swift test --filter TeamPresenceStorageTests
swift test --filter PresenceMonitorTests
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift Sources/GrafttyKit/Teams Tests/GrafttyTests/Specs/IdleDeliveryTests.swift Tests/GrafttyKitTests/Teams
git commit -m "fix(teams): route delivery by live pane session identity"
```

## Task 7: Finish The Rename And Remove Compatibility

**Files:**
- Modify: all remaining files containing `TerminalID`
- Modify: `Sources/GrafttyKit/Model/PaneSlotID.swift`
- Update tests found by search.

- [ ] **Step 1: Search for old name**

Run:

```bash
rg -n "TerminalID" Sources Tests
```

Expected before this task: remaining hits in files not yet renamed.

- [ ] **Step 2: Rename remaining code references**

Change remaining production and test references to `PaneSlotID`.

Keep historical comments only if they describe migration from old persisted data; otherwise update comments too.

- [ ] **Step 3: Remove compatibility alias**

Delete from `PaneSlotID.swift`:

```swift
@available(*, deprecated, renamed: "PaneSlotID")
public typealias TerminalID = PaneSlotID
```

- [ ] **Step 4: Verify no old name remains**

Run:

```bash
rg -n "TerminalID" Sources Tests
```

Expected: no output, or only deliberately retained migration comments. If comments remain, verify they are useful and not stale.

- [ ] **Step 5: Run compile and focused tests**

Run:

```bash
swift test --filter SplitTreeTests
swift test --filter WorktreeEntryTests
swift test --filter TerminalManagerMetadataTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests
git commit -m "refactor(panes): complete PaneSlotID rename"
```

## Task 8: Full Verification And Cleanup

**Files:**
- Review all touched files.
- Update docs only if code comments or specs still claim zmx names derive from pane slots.

- [ ] **Step 1: Run full test suite**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 2: Run whitespace check**

Run:

```bash
git diff --check
```

Expected: no output.

- [ ] **Step 3: Run targeted search checks**

Run:

```bash
rg -n "sessionName\\(for: .*\\.id\\)|ZmxLauncher\\.sessionName\\(for: .*Slot|TerminalID|TeamDeliveryPaneResolver" Sources Tests
```

Expected:

- no `TerminalID`
- no `TeamDeliveryPaneResolver`
- no zmx session derivation from slot IDs

- [ ] **Step 4: Use simplify review**

Run the `simplify` skill on the final diff. Specific questions to answer:

- Is there any remaining path where a layout slot ID can derive a zmx session name?
- Does Stop clear sessions in every all-pane teardown path?
- Does app relaunch preserve sessions only for worktrees already marked running?
- Does moving a pane preserve its session?
- Are there any stale comments saying pane IDs and zmx session names are the same thing?

- [ ] **Step 5: Final full verification**

Run again after any cleanup:

```bash
swift test
git diff --check
```

Expected: all tests pass; diff check clean.

- [ ] **Step 6: Commit final cleanup**

```bash
git add .
git commit -m "chore(panes): clean up slot session identity migration"
```

## Risks And Design Checks

- Existing running zmx sessions must survive the first upgrade. The migration path `PaneSessionID.migratedFromLegacySlot(_:)` is required for this.
- Stop must mean "end runtime identity." If a caller marks a worktree closed without destroying surfaces first, that is a bug this plan should expose in tests.
- Pane move must preserve session identity. Moving is spatial, not runtime lifecycle.
- App quit/relaunch must preserve session identity for worktrees persisted as `.running`.
- Team delivery should not inspect process names. Live session identity is the safety gate.
- `PaneSlotID` should never be accepted by zmx APIs once the compatibility alias is removed.

