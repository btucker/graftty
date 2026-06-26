# Delivery Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement runtime-agnostic automatic team inbox delivery ownership so only the first live registered agent per `(team, worktree, runtime)` receives automatic delivery.

**Architecture:** Add stable process identity to presence records, then build a shared `TeamDeliveryOwnershipResolver` over presence records. Gate Claude watcher/render delivery and make the existing Codex legacy zmx delivery path primary-only through that shared resolver; leave Codex app-server transport disabled until an implementation plan identifies a reliable thread-idle signal.

**Tech Stack:** Swift 5.10, Swift Testing, `GrafttyKit`, `GrafttyCLI`, Darwin `proc_pidinfo`, existing team inbox/presence infrastructure.

---

## Scope

This plan implements the approved spec's shared ownership foundation and applies it to current delivery paths:

- Presence records carry optional `processStartTimeMicroseconds`.
- Ownership resolver returns one owner per `(teamID, worktree, runtime)`.
- Claude `watch-inbox` arms only for the owner.
- Claude hook rendering/advancing only consumes automatic inbox messages for the owner.
- Codex legacy zmx delivery becomes owner/primary-only.

This plan does **not** implement Codex app-server delivery. The spec requires a reliable app-server idle/running signal before enabling that transport; keep legacy zmx delivery as the pre-app-server path.

## File Structure

- Create `Sources/GrafttyKit/Process/ProcessIdentityReader.swift`
  - Reads process start time for a PID using Darwin `proc_pidinfo(PROC_PIDTBSDINFO)`.
- Modify `Sources/GrafttyKit/Teams/TeamPresence.swift`
  - Add optional `processStartTimeMicroseconds` to `TeamPresenceRecord`.
  - Keep decoding old records where the field is absent.
  - Store process start time as a lossless integer microsecond timestamp.
  - Add process identity validation to stale cleanup.
- Modify `Sources/GrafttyKit/Teams/AgentHookInstaller.swift`
  - Start the real runtime as a child, register that child PID, then wait.
- Modify `Sources/GrafttyCLI/Team.swift`
  - Add `team register --pid <pid>` and capture process identity for that runtime PID.
  - Gate `team watch-inbox` through the ownership resolver before constructing `InboxWatcher`.
- Create `Sources/GrafttyKit/Teams/TeamDeliveryOwnership.swift`
  - Shared owner key, owner, candidate, process liveness protocol, and resolver.
- Modify `Sources/GrafttyKit/Teams/TeamDeliverySessionResolution.swift`
  - Make Codex session resolution return the single current owner session.
  - Keep `stopSessionName` as a live-pane check for state transitions only.
- Modify `Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift`
  - Inject optional ownership resolver/candidate resolver.
  - Gate automatic inbox delivery and cursor/watermark advance for hook paths.
- Modify `Sources/Graftty/GrafttyApp.swift`
  - Use the resolver-backed Codex session resolution with process identity validation.
- Modify `Sources/GrafttyKit/Teams/IdleDeliveryService.swift`
  - Make nudge sends report success before zmx watermark advancement.
- Tests:
  - `Tests/GrafttyKitTests/Process/ProcessIdentityReaderTests.swift`
  - `Tests/GrafttyKitTests/Teams/TeamPresenceStorageTests.swift`
  - `Tests/GrafttyKitTests/Teams/TeamDeliveryOwnershipTests.swift`
  - `Tests/GrafttyKitTests/Teams/TeamDeliverySessionResolutionTests.swift`
  - `Tests/GrafttyKitTests/Teams/TeamInboxRequestHandlerTests.swift`
  - `Tests/GrafttyTests/Specs/TeamWatchInboxOwnershipTests.swift`

## Test Commands

Use targeted tests during tasks:

```bash
swift test --filter ProcessIdentityReaderTests
swift test --filter TeamPresenceStorage
swift test --filter TeamDeliveryOwnership
swift test --filter TeamDeliverySessionResolution
swift test --filter TeamInboxRequestHandler
swift test --filter TeamWatchInboxOwnership
```

Use full verification before final completion:

```bash
swift test
```

---

### Task 1: Presence Process Identity

**Files:**
- Create: `Sources/GrafttyKit/Process/ProcessIdentityReader.swift`
- Modify: `Sources/GrafttyKit/Teams/TeamPresence.swift`
- Modify: `Sources/GrafttyKit/Teams/AgentHookInstaller.swift`
- Modify: `Sources/GrafttyCLI/Team.swift`
- Test: `Tests/GrafttyKitTests/Process/ProcessIdentityReaderTests.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamPresenceStorageTests.swift`
- Test: `Tests/GrafttyTests/Specs/AgentHookInstallerWrapperTests.swift`

- [ ] **Step 1: Write failing presence storage tests**

Add tests proving:

```swift
@Test("Presence records round-trip processStartTimeMicroseconds when present.")
func roundTripsProcessStartTimeMicroseconds() throws {
    let storage = try makeStorage()
    let start = Int64(1_700_000_123_456_789)
    let record = TeamPresenceRecord(
        teamID: "/repo",
        worktree: "/repo/.worktrees/alice",
        runtime: .codex,
        paneSessionName: "graftty-abc12345",
        pid: 4242,
        processStartTimeMicroseconds: start,
        registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    try storage.write(record)

    let loaded = try #require(storage.listAll().first)
    #expect(loaded.processStartTimeMicroseconds == start)
}

@Test("Old presence records decode with nil processStartTimeMicroseconds for back-compat.")
func decodesNilProcessStartTimeMicrosecondsWhenFieldMissing() throws {
    // Write old JSON without processStartTimeMicroseconds and assert loaded.processStartTimeMicroseconds == nil.
}
```

Update existing test fixtures in this file to pass `processStartTimeMicroseconds: nil` or a fixed integer.

- [ ] **Step 2: Run presence storage tests and verify RED**

Run:

```bash
swift test --filter TeamPresenceStorage
```

Expected: FAIL because `TeamPresenceRecord` has no `processStartTimeMicroseconds`.

- [ ] **Step 3: Implement optional `processStartTimeMicroseconds` on presence records**

In `TeamPresenceRecord`:

```swift
public let processStartTimeMicroseconds: Int64?
```

Update the initializer:

```swift
processStartTimeMicroseconds: Int64? = nil,
registeredAt: Date
```

Keep the default so older test call sites can be migrated gradually, but update touched tests explicitly for clarity.

- [ ] **Step 4: Run presence storage tests and verify GREEN**

Run:

```bash
swift test --filter TeamPresenceStorage
```

Expected: PASS.

- [ ] **Step 5: Write failing process identity reader tests**

Create `Tests/GrafttyKitTests/Process/ProcessIdentityReaderTests.swift`:

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("ProcessIdentityReader")
struct ProcessIdentityReaderTests {
    @Test("Returns start time microseconds for the current process.")
    func returnsStartTimeMicrosecondsForCurrentProcess() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = try #require(ProcessIdentityReader.startTimeMicroseconds(ofPID: pid))
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        #expect(start > 0)
        #expect(start <= now)
    }

    @Test("Returns nil for a non-existent process.")
    func returnsNilForMissingProcess() {
        #expect(ProcessIdentityReader.startTimeMicroseconds(ofPID: 999_999) == nil)
    }

    @Test("Microsecond conversion is lossless for proc timeval parts.")
    func microsecondConversionIsLossless() {
        #expect(ProcessIdentityReader.microseconds(seconds: 1_700_000_123, microseconds: 456_789) == 1_700_000_123_456_789)
    }
}
```

- [ ] **Step 6: Run process identity tests and verify RED**

Run:

```bash
swift test --filter ProcessIdentityReader
```

Expected: FAIL because `ProcessIdentityReader` does not exist.

- [ ] **Step 7: Implement `ProcessIdentityReader`**

Create `Sources/GrafttyKit/Process/ProcessIdentityReader.swift`:

```swift
import Foundation
import Darwin

public enum ProcessIdentityReader {
    public static func startTimeMicroseconds(ofPID pid: Int32) -> Int64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard rc == size else { return nil }
        return microseconds(
            seconds: Int64(info.pbi_start_tvsec),
            microseconds: Int64(info.pbi_start_tvusec)
        )
    }

    public static func microseconds(seconds: Int64, microseconds: Int64) -> Int64 {
        seconds * 1_000_000 + microseconds
    }
}
```

- [ ] **Step 8: Run process identity tests and verify GREEN**

Run:

```bash
swift test --filter ProcessIdentityReader
```

Expected: PASS.

- [ ] **Step 9: Write failing stale cleanup tests for process identity**

In `PresenceMonitorTests`, add a test that writes two records with the same alive PID but one mismatched start time. Use injected validation to avoid depending on the real process table:

```swift
TeamPresenceMonitor.cleanupStale(
    storage: storage,
    isAlive: { _ in true },
    isSameProcess: { record in record.processStartTimeMicroseconds == expectedStart },
    eventLog: ...
)
```

Expected behavior: records whose `isSameProcess` returns false are deleted.

- [ ] **Step 10: Run stale cleanup tests and verify RED**

Run:

```bash
swift test --filter PresenceMonitor
```

Expected: FAIL because `cleanupStale` has no process-identity validation hook.

- [ ] **Step 11: Implement process identity cleanup**

Extend `TeamPresenceMonitor.cleanupStale`:

```swift
isSameProcess: (TeamPresenceRecord) -> Bool = { record in
    guard let expected = record.processStartTimeMicroseconds,
          let actual = ProcessIdentityReader.startTimeMicroseconds(ofPID: record.pid) else {
        return false
    }
    return actual == expected
}
```

Delete records when `!isAlive(record.pid) || !isSameProcess(record)`.

Use a different event detail reason for identity mismatch, e.g. `process_identity_mismatch`.

- [ ] **Step 12: Update the wrapper to register the real runtime PID**

The current wrapper backgrounds `team register` before the runtime starts, which records the short-lived CLI helper PID. Change the wrapper shape so it starts the real runtime in the background, registers that child PID, waits for it, then exits with the child status.

The generated shell should have this shape for both Claude and Codex runtime branches:

```sh
( exec "$real_binary" ... "$@" ) &
agent_pid=$!
"$graftty" team register --runtime <runtime> --pid "$agent_pid" >/dev/null 2>&1 || true
wait "$agent_pid"
status=$?
exit "$status"
```

Keep the existing cleanup trap so unregister runs when the wrapper exits. Keep Codex `internal sync-codex-home` before spawning the child.

Update `AgentHookInstallerWrapperTests.wrapperRegistersAsynchronouslyBeforeExec` into a new expectation:

- wrapper contains `team register --runtime <runtime> --pid "$agent_pid"`;
- register appears after `agent_pid=$!`;
- wrapper contains `wait "$agent_pid"`;
- trap unregister remains.

- [ ] **Step 13: Update `team register` to accept and record the runtime PID**

Add an optional `--pid` to `TeamRegister`:

```swift
@Option(name: .long, help: "PID of the long-running agent process to register")
var pid: Int32?
```

In `run`, use:

```swift
let runtimePID = pid ?? ProcessInfo.processInfo.processIdentifier
let processStartTimeMicroseconds = ProcessIdentityReader.startTimeMicroseconds(ofPID: runtimePID)
```

Pass `runtimePID` and `processStartTimeMicroseconds` into `TeamPresenceRecord`. The wrapper should always pass the runtime child PID; the default remains for direct/test invocation.

- [ ] **Step 14: Run targeted tests**

Run:

```bash
swift test --filter TeamPresenceStorage
swift test --filter ProcessIdentityReader
swift test --filter PresenceMonitor
swift test --filter AgentHookInstaller
```

Expected: PASS.

- [ ] **Step 15: Commit**

```bash
git add Sources/GrafttyKit/Process/ProcessIdentityReader.swift Sources/GrafttyKit/Teams/TeamPresence.swift Sources/GrafttyKit/Teams/AgentHookInstaller.swift Sources/GrafttyCLI/Team.swift Tests/GrafttyKitTests/Process/ProcessIdentityReaderTests.swift Tests/GrafttyKitTests/Teams/TeamPresenceStorageTests.swift Tests/GrafttyTests/Specs/PresenceMonitorTests.swift Tests/GrafttyTests/Specs/AgentHookInstallerWrapperTests.swift
git commit -m "Add process identity to team presence"
```

---

### Task 2: Shared Delivery Ownership Resolver

**Files:**
- Create: `Sources/GrafttyKit/Teams/TeamDeliveryOwnership.swift`
- Modify: `Sources/GrafttyKit/Teams/TeamDeliverySessionResolution.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamDeliveryOwnershipTests.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamDeliverySessionResolutionTests.swift`

- [ ] **Step 1: Write failing ownership resolver tests**

Create `Tests/GrafttyKitTests/Teams/TeamDeliveryOwnershipTests.swift` covering:

- earliest live record wins for `(teamID, worktree, runtime)`;
- records without `paneSessionName` are ignored;
- records whose pane session is not live are ignored;
- records whose process identity is not valid are ignored;
- reused PID with different process start time is ignored;
- team/worktree/runtime filters are respected;
- ties sort by `paneSessionName`, then `pid`;
- `isOwner` returns true only for the owner candidate.

Use a fake liveness object:

```swift
struct FakeDeliveryLiveness: TeamDeliveryLivenessChecking {
    var liveSessions: Set<String> = []
    var processStartTimes: [Int32: Int64] = [:]

    func isLivePaneSession(_ sessionName: String) -> Bool {
        liveSessions.contains(sessionName)
    }

    func processStartTimeMicroseconds(ofPID pid: Int32) -> Int64? {
        processStartTimes[pid]
    }
}
```

- [ ] **Step 2: Run ownership tests and verify RED**

Run:

```bash
swift test --filter TeamDeliveryOwnership
```

Expected: FAIL because ownership types do not exist.

- [ ] **Step 3: Implement ownership types and resolver**

Create `Sources/GrafttyKit/Teams/TeamDeliveryOwnership.swift`:

```swift
public struct TeamDeliveryOwnerKey: Hashable, Sendable {
    public let teamID: String
    public let worktree: String
    public let runtime: TeamHookRuntime
}

public struct TeamDeliveryOwner: Equatable, Sendable {
    public let key: TeamDeliveryOwnerKey
    public let paneSessionName: String
    public let pid: Int32
    public let processStartTimeMicroseconds: Int64
    public let registeredAt: Date
    public let runtimeSessionID: String?
}

public struct TeamDeliveryOwnerCandidate: Sendable {
    public let key: TeamDeliveryOwnerKey
    public let paneSessionName: String?
    public let pid: Int32?
    public let processStartTimeMicroseconds: Int64?
    public let runtimeSessionID: String?
}

public protocol TeamDeliveryLivenessChecking: Sendable {
    func isLivePaneSession(_ sessionName: String) -> Bool
    func processStartTimeMicroseconds(ofPID pid: Int32) -> Int64?
}

public struct TeamDeliveryOwnershipResolver: Sendable {
    public let records: @Sendable () -> [TeamPresenceRecord]
    public let liveness: TeamDeliveryLivenessChecking
    ...
}
```

Resolver rules:

1. Match `teamID`, `worktree`, `runtime`.
2. Require `paneSessionName`.
3. Require `liveness.isLivePaneSession(paneSessionName)`.
4. Require `record.processStartTimeMicroseconds`.
5. Require `liveness.processStartTimeMicroseconds(ofPID: record.pid) == record.processStartTimeMicroseconds`.
6. Sort by `registeredAt`, then `paneSessionName`, then `pid`.

`isOwner` should always compare key and pane session. If the candidate also supplies `pid` or `processStartTimeMicroseconds`, compare those fields too. Hook and watcher helper processes usually cannot have the runtime PID; they prove they act for the owner by inheriting the owner pane identity.

- [ ] **Step 4: Run ownership tests and verify GREEN**

Run:

```bash
swift test --filter TeamDeliveryOwnership
```

Expected: PASS.

- [ ] **Step 5: Write failing Codex session resolution tests**

Update `TeamDeliverySessionResolutionTests`:

- `codexSessionNames` returns only the owner session, not every live session.
- earlier record wins even when a later record is also live.
- missing/mismatched `processStartTimeMicroseconds` excludes a record.

The expected output should be a one-element array or empty array.

- [ ] **Step 6: Run session resolution tests and verify RED**

Run:

```bash
swift test --filter TeamDeliverySessionResolution
```

Expected: FAIL because the resolver still returns every live Codex session and only checks PID.

- [ ] **Step 7: Update `TeamDeliverySessionResolution.codexSessionNames`**

Change the function signature to accept stronger liveness:

```swift
public static func codexSessionNames(
    teamID: String,
    in worktree: String,
    records: [TeamPresenceRecord],
    isLiveSession: (String) -> Bool,
    processStartTimeMicroseconds: (Int32) -> Int64?
) -> [String]
```

Implementation should instantiate `TeamDeliveryOwnershipResolver` and return `[owner.paneSessionName]` if an owner exists, else `[]`.

Keep `stopSessionName` unchanged except for call-site compatibility. It should remain a live-pane guard for state transitions; ownership is applied before delivery.

- [ ] **Step 8: Run ownership and session resolution tests**

Run:

```bash
swift test --filter TeamDeliveryOwnership
swift test --filter TeamDeliverySessionResolution
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamDeliveryOwnership.swift Sources/GrafttyKit/Teams/TeamDeliverySessionResolution.swift Tests/GrafttyKitTests/Teams/TeamDeliveryOwnershipTests.swift Tests/GrafttyKitTests/Teams/TeamDeliverySessionResolutionTests.swift
git commit -m "Add team delivery ownership resolver"
```

---

### Task 3: Owner-Gated Hook Inbox Rendering

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamInboxRequestHandlerTests.swift`

- [ ] **Step 1: Write failing hook gating tests**

Add tests to `TeamInboxRequestHandlerTests`:

1. Owner `PostToolUse` receives urgent messages and advances cursor as today.
2. Non-owner `PostToolUse` does not render urgent inbox messages and does not advance cursor or worktree watermark.
3. When no ownership resolver is injected, behavior remains backward-compatible.

Use an injected predicate in the handler test setup:

```swift
automaticDeliveryOwner: { _, _, _, paneSessionName in
    paneSessionName == "graftty-owner"
}
```

Build the non-owner call with `paneSessionName: "graftty-secondary"` and assert:

```swift
#expect(!output.contains("urgent body"))
#expect(try inbox.cursor(teamID: "/repo", sessionID: "secondary")?.lastSeenID == nil)
#expect(try inbox.worktreeWatermark(teamID: "/repo", worktree: "/repo/.worktrees/alice") == nil)
```

- [ ] **Step 2: Run request handler tests and verify RED**

Run:

```bash
swift test --filter TeamInboxRequestHandler
```

Expected: FAIL because `TeamInboxRequestHandler` has no owner gating.

- [ ] **Step 3: Add owner-gating injection to `TeamInboxRequestHandler`**

Add a small injected closure, not direct storage dependencies:

```swift
private let automaticDeliveryOwner: (@Sendable (
    _ teamID: String,
    _ worktree: String,
    _ runtime: TeamHookRuntime,
    _ paneSessionName: String?
) -> Bool)?
```

Default `nil` preserves existing tests and non-app contexts.

Add helper:

```swift
private func canConsumeAutomaticInbox(
    teamID: String,
    worktree: String,
    runtime: TeamHookRuntime,
    paneSessionName: String?
) -> Bool {
    automaticDeliveryOwner?(teamID, worktree, runtime, paneSessionName) ?? true
}
```

- [ ] **Step 4: Gate `postToolUse` delivery and advancement**

In `.postToolUse`, call `onPostToolUse` as today, then:

```swift
guard canConsumeAutomaticInbox(...) else {
    return try TeamHookRenderer.postToolUse(runtime: runtime, messages: [])
}
```

Only owners read unread messages for automatic rendering and advance cursor/watermark.

- [ ] **Step 5: Keep Stop non-consuming**

Stop already returns `{}` and does not advance state. No delivery is needed there, but leave a comment that owner-gating for Stop is handled by watcher gating and non-consuming behavior.

- [ ] **Step 6: Wire production hook delivery to the resolver**

Update `handlePaneRequest` and `handleTeamHook` so `handleTeamHook` receives `terminalManager`.

In `handleTeamHook`, pass an `automaticDeliveryOwner` closure into `teamInboxRequestHandler`. The closure should:

1. Load current presence records from `TeamPresenceStorage.defaultRoot()`.
2. Build `TeamDeliveryOwnershipResolver` with:
   - `isLivePaneSession: { terminalManager.handle(forSessionName: $0) != nil }`
   - `processStartTimeMicroseconds: { ProcessIdentityReader.startTimeMicroseconds(ofPID: $0) }`
3. Ask for the owner of `(teamID, worktree, runtime)`.
4. Return true only when `owner?.paneSessionName == paneSessionName`.

If `paneSessionName` is nil, return false for automatic inbox consumption. Session primers still render at SessionStart; this gate only controls unread inbox rendering and cursor/watermark advancement.

Add a production-path unit test if practical by calling `handleTeamHook` directly with a fake or minimal terminal manager is already possible. If that is not practical because `TerminalManager` is UI-heavy, add a `TeamInboxRequestHandler` test that uses a real `TeamDeliveryOwnershipResolver` over two presence records instead of a hard-coded predicate. The test must prove a secondary Claude `PostToolUse` does not render or advance.

- [ ] **Step 7: Run request handler tests and verify GREEN**

Run:

```bash
swift test --filter TeamInboxRequestHandler
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift Sources/Graftty/GrafttyApp.swift Tests/GrafttyKitTests/Teams/TeamInboxRequestHandlerTests.swift
git commit -m "Gate hook inbox delivery to owner"
```

---

### Task 4: Claude Watcher Ownership Gate

**Files:**
- Modify: `Sources/GrafttyCLI/Team.swift`
- Test: `Tests/GrafttyTests/Specs/TeamWatchInboxOwnershipTests.swift`

- [ ] **Step 1: Extract testable watch decision helper**

Before production wiring, add tests for a pure helper in `GrafttyKit` or an internal CLI-adjacent type. Preferred location: create `Sources/GrafttyKit/Teams/TeamWatchInboxOwnership.swift` so tests can avoid running a long-lived CLI process.

The helper should take:

```swift
public struct TeamWatchInboxOwnershipDecision {
    public let shouldArmWatcher: Bool
    public let sessionID: String
}
```

Inputs:

- runtime
- hook payload session id
- fallback session id generator
- teamID
- worktree
- paneSessionName
- ownership resolver

- [ ] **Step 2: Write failing watcher decision tests**

Create tests proving:

- owner Claude session returns `shouldArmWatcher == true`;
- non-owner Claude session returns `false`;
- missing `paneSessionName` returns `false`;
- missing/verifiably mismatched presence `processStartTimeMicroseconds` returns `false`;
- subagent Stop payload is still skipped by existing `AgentStopHookFilter` path in CLI tests if a suitable test already exists.

- [ ] **Step 3: Run watcher ownership tests and verify RED**

Run:

```bash
swift test --filter TeamWatchInboxOwnership
```

Expected: FAIL because helper does not exist.

- [ ] **Step 4: Implement watch ownership helper**

Create `Sources/GrafttyKit/Teams/TeamWatchInboxOwnership.swift`.

The helper should build a `TeamDeliveryOwnerCandidate`:

```swift
TeamDeliveryOwnerCandidate(
    key: .init(teamID: teamID, worktree: worktree, runtime: runtime),
    paneSessionName: paneSessionName,
    pid: nil,
    processStartTimeMicroseconds: nil,
    runtimeSessionID: sessionID
)
```

Return `shouldArmWatcher` from `resolver.isOwner(candidate, for: key)`.

- [ ] **Step 5: Wire CLI `team watch-inbox`**

In `TeamWatchInbox.run`:

1. Resolve `paneSessionName` with `TeamRegisterPaneResolver`.
2. Load `TeamPresenceStorage.defaultRoot().listAll()`.
3. Build `TeamDeliveryOwnershipResolver` with:
   - `isLivePaneSession`: return true for any nonempty recorded pane session. The CLI cannot ask the app which panes are live, and treating only the current pane as live lets every secondary watcher elect itself. Process identity validation below is the stale-record guard in this process-only context.
   - `processStartTimeMicroseconds`: `ProcessIdentityReader.startTimeMicroseconds(ofPID:)`.
4. Build the candidate from `paneSessionName` and `sessionID` only; do not use the watcher helper process PID.
5. If decision says not owner, return without constructing `InboxWatcher`.

This makes non-owner Claude watchers exit quietly.

- [ ] **Step 6: Run watcher tests and compile CLI**

Run:

```bash
swift test --filter TeamWatchInboxOwnership
swift build --target GrafttyCLI
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamWatchInboxOwnership.swift Sources/GrafttyCLI/Team.swift Tests/GrafttyTests/Specs/TeamWatchInboxOwnershipTests.swift
git commit -m "Gate Claude inbox watcher to delivery owner"
```

---

### Task 5: Wire Ownership Into App Delivery Paths

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamDeliverySessionResolutionTests.swift`
- Test: `Tests/GrafttyTests/Specs/IdleDeliveryTests.swift` if existing expectations assume fanout.
- Test: `Tests/GrafttyKitTests/Teams/IdleDeliveryEndToEndTests.swift`

- [ ] **Step 1: Write failing Codex primary-only delivery test**

In `TeamDeliverySessionResolutionTests`, add or update a test with two live Codex records in the same worktree:

```swift
let earlier = record(sessionName: "graftty-owner", pid: 101, registeredAt: old)
let later = record(sessionName: "graftty-secondary", pid: 102, registeredAt: newer)
let resolved = TeamDeliverySessionResolution.codexSessionNames(...)
#expect(resolved == ["graftty-owner"])
```

Also add a test that a live pane with mismatched process start time returns `[]`.

- [ ] **Step 2: Run session resolution tests and verify RED if not already covered**

Run:

```bash
swift test --filter TeamDeliverySessionResolution
```

Expected: FAIL until call sites use the new signature and resolver behavior.

- [ ] **Step 3: Update `GrafttyApp` Codex session resolution**

In `codexSessionNamesIn`, pass:

```swift
teamID: repo.path
processStartTimeMicroseconds: { ProcessIdentityReader.startTimeMicroseconds(ofPID: $0) }
```

The closure currently only receives `worktreePath`; update it to resolve `teamID` from `binding.wrappedValue.repos` before calling session resolution. Keep the existing `TerminalManager` live pane check:

```swift
isLiveSession: { tm.handle(forSessionName: $0) != nil }
```

For call sites that already know `teamID`, prefer a closure shaped like:

```swift
let codexSessionNamesIn: @Sendable (_ teamID: String, _ worktreePath: String) -> [String]
```

Then update `graceScheduler` and inbox observer calls.

- [ ] **Step 4: Ensure Stop still updates state for live panes**

Do not make `stopSessionName` owner-only. It is used to find pane input state and transition the state machine.

For delivery, do **not** pass `[liveSessionName]` from `stopSessionName` into `IdleDeliveryService.onStop`. After updating state, compute:

```swift
let ownerSessionNames = codexSessionNamesIn(team, worktree)
Task { await service.onStop(team: team, worktree: worktree, sessionNames: ownerSessionNames) }
```

This means a non-owner Codex Stop can update the state machine, but any delivery attempt targets the current owner session. If there is no owner, `sessionNames` is empty and the service logs/skips without advancing the watermark.

- [ ] **Step 5: Make nudge delivery failure-aware**

Change `NudgeSender`:

```swift
public protocol NudgeSender: Sendable {
    func send(sessionName: String, message: String, messageIDs: [String]) async -> Bool
}
```

Update `ZmxNudgeSender.send` to return `true` only when `writer.write(...)` succeeds; return `false` when it catches an error.

Update test stubs to record sends and return configurable success/failure.

Update `IdleDeliveryService.maybeDeliver`:

```swift
var deliveredToAtLeastOneSession = false
for sessionName in sessionNames {
    let sent = await nudgeSender.send(...)
    deliveredToAtLeastOneSession = deliveredToAtLeastOneSession || sent
}
guard deliveredToAtLeastOneSession else {
    log(... outcome: "error_nudge_send")
    return
}
try inbox.advanceZmxWatermark(...)
```

This preserves the spec invariant: failed delivery attempts do not advance zmx watermark state.

- [ ] **Step 6: Add failure-aware idle delivery tests**

Add or update tests proving:

- when all `NudgeSender` sends fail, no zmx watermark is advanced;
- when the owner session send succeeds, the zmx watermark advances;
- when a non-owner Codex Stop fires, delivery targets `codexSessionNamesIn(team, worktree)`, not the stopping pane session.

- [ ] **Step 7: Run focused tests and build app target**

Run:

```bash
swift test --filter TeamDeliverySessionResolution
swift test --filter IdleDeliveryService
swift test --filter IdleDeliveryEndToEnd
swift build --target Graftty
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift Sources/GrafttyKit/Teams/TeamDeliverySessionResolution.swift Sources/GrafttyKit/Teams/IdleDeliveryService.swift Tests/GrafttyKitTests/Teams/TeamDeliverySessionResolutionTests.swift Tests/GrafttyTests/Specs/IdleDeliveryTests.swift Tests/GrafttyKitTests/Teams/IdleDeliveryEndToEndTests.swift
git commit -m "Use delivery ownership for Codex idle delivery"
```

---

### Task 6: Final Verification And Review

**Files:**
- Review all files changed by Tasks 1-5.

- [ ] **Step 1: Run full test suite**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 2: Run final build**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 3: Inspect git history and status**

Run:

```bash
git status --short --branch
git log --oneline --decorate -8
```

Expected: clean working tree, recent commits correspond to the implementation tasks.

- [ ] **Step 4: Dispatch final code review**

Use a reviewer subagent with:

- spec path: `docs/superpowers/specs/2026-06-18-delivery-ownership-design.md`
- plan path: `docs/superpowers/plans/2026-06-18-delivery-ownership.md`
- diff range: from the commit before Task 1 through `HEAD`

The reviewer should prioritize correctness risks, duplicate-delivery gaps, cursor/watermark advancement bugs, process identity edge cases, and missing tests.

- [ ] **Step 5: Fix review issues if any**

If the final reviewer finds blocking issues, fix them with TDD and rerun the relevant focused tests plus `swift test`.

- [ ] **Step 6: Final status**

Report:

- commits created;
- tests/builds run and their exit status;
- any known gaps, especially that Codex app-server delivery remains intentionally disabled until a reliable idle/running signal is pinned.
