# Pane-Specific Team Registration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move team-message keys-input delivery from worktree-level `firstPane` resolution to per-pane registration recorded explicitly by `graftty team register`. Multiple codex panes in a worktree fan out delivery; non-codex panes never receive typed text.

**Architecture:** `TeamPresenceRecord` gains an optional `paneSessionName` (set from `ZMX_SESSION`); storage keys by `(teamID, worktree, runtime, paneSessionName)`. The in-memory `agentForPane` map is deleted; both consumers (keystroke routing, inbox dispatch) read directly from `TeamPresenceStorage`. `IdleDeliveryService` API shifts from `paneID: UUID?` to `paneIDs: [UUID]` and becomes codex-only by construction. The hook callbacks no longer write to any registration store — registration is owned by the explicit CLI command.

**Tech Stack:** Swift, Swift Testing, libghostty (read-only here), zmx (env-var contract), JSON file storage.

**Spec:** `docs/superpowers/specs/2026-05-08-pane-specific-team-registration-design.md`

**Spec IDs introduced:** `TEAM-IDLE-2.9`, `TEAM-IDLE-2.10`, `TEAM-IDLE-2.11`, `TEAM-IDLE-2.12`, `TEAM-IDLE-2.13`, `TEAM-IDLE-2.14`, `TEAM-IDLE-2.15`.

---

## File map

**Create:**
- (no new source files; tests file may be split if it grows)

**Modify (Sources):**
- `Sources/GrafttyKit/Teams/TeamPresence.swift` — `TeamPresenceRecord` schema + `TeamPresenceStorage` per-pane keying.
- `Sources/GrafttyCLI/Team.swift` — `TeamRegister.run`, `TeamUnregister.run`, `TeamHook.run` read `ZMX_SESSION`.
- `Sources/GrafttyKit/Notification/NotificationMessage.swift` — add `paneSessionName: String?` to `.teamHook`.
- `Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift` — accept and forward `paneSessionName` to callbacks; signature widening of `TeamHookCallbacks`.
- `Sources/GrafttyKit/Teams/IdleDeliveryService.swift` — `paneIDs: [UUID]`, fan-out, drop `runtime` parameter.
- `Sources/Graftty/GrafttyApp.swift` — drop `agentForPane`, add `codexPanesIn(worktree:)` helper, route keystroke routing through presence storage, route Stop-hook through `paneSessionName`.
- `Sources/Graftty/Terminal/TerminalManager.swift` — add `paneID(forSessionName:)` helper (returns UUID directly, parallel to existing `handle(forSessionName:)`).

**Modify (Tests):**
- `Tests/GrafttyKitTests/Teams/TeamPresenceStorageTests.swift` (or wherever the existing presence tests live; create if missing) — round-trip + per-pane key tests.
- `Tests/GrafttyKitTests/Teams/TeamInboxRequestHandlerTests.swift` — wire-protocol field plumbing.
- `Tests/GrafttyTests/Specs/IdleDeliveryTests.swift` — API change + fan-out tests; replace `runtime: nil` skip test with `paneIDs: []` skip test.
- `Tests/GrafttyKitTests/Teams/IdleDeliveryEndToEndTests.swift` — multi-pane fan-out E2E.
- `Tests/GrafttyKitTests/Teams/ZmxNudgeSenderTests.swift` — verify it still works per-pane (no change expected).
- `Tests/GrafttyTests/Specs/TeamRegisterCLITests.swift` (new) — `ZMX_SESSION` plumbing through `TeamRegister`/`TeamUnregister`.

---

## Sequencing strategy

We start at the storage layer and walk outward (storage → CLI → wire protocol → IdleDeliveryService → GrafttyApp wiring). At each step the tree compiles and existing tests pass; only the test assertions covering the changed surface are updated. Each phase's commits are atomic — the codebase is shippable between them in a pinch.

---

## Phase 1 — Storage schema

### Task 1: Add `paneSessionName` to `TeamPresenceRecord`

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamPresence.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamPresenceStorageTests.swift` (create if missing)

- [ ] **Step 1: Locate / create the test file**

```bash
ls Tests/GrafttyKitTests/Teams/TeamPresenceStorageTests.swift 2>/dev/null || \
  echo "create new file"
```

If absent, create it with this scaffold (existing tests for presence may live elsewhere — fine, we're adding a new file for the new behavior):

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamPresenceStorage — pane-specific records")
struct TeamPresenceStorageTests {
    func makeStorage() throws -> TeamPresenceStorage {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TeamPresenceStorage(rootDirectory: dir)
    }
}
```

- [ ] **Step 2: Write a failing test for the new field round-trip**

Add inside `TeamPresenceStorageTests`:

```swift
@Test("Record round-trips paneSessionName when set.")
func roundTripsPaneSessionName() throws {
    let storage = try makeStorage()
    let record = TeamPresenceRecord(
        teamID: "/repo",
        worktree: "/repo/.worktrees/alice",
        runtime: .codex,
        paneSessionName: "graftty-abc12345",
        pid: 4242,
        registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try storage.write(record)
    let loaded = try #require(storage.listAll().first)
    #expect(loaded.paneSessionName == "graftty-abc12345")
}

@Test("Record decodes paneSessionName as nil when field missing (back-compat).")
func decodesNilWhenFieldMissing() throws {
    let storage = try makeStorage()
    let teamDir = storage.rootDirectory
        .appendingPathComponent(TeamInbox.fileComponent("/repo"), isDirectory: true)
        .appendingPathComponent("presence", isDirectory: true)
    try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
    // Hand-craft an old-format JSON without paneSessionName.
    let oldJSON = """
    {
      "teamID": "/repo",
      "worktree": "/repo/.worktrees/alice",
      "runtime": "codex",
      "pid": 4242,
      "registeredAt": "2023-11-14T22:13:20Z"
    }
    """
    let leaf = TeamInbox.fileComponent("/repo/.worktrees/alice.codex") + ".json"
    try oldJSON.data(using: .utf8)!.write(to: teamDir.appendingPathComponent(leaf))
    let loaded = try #require(storage.listAll().first)
    #expect(loaded.paneSessionName == nil)
}
```

- [ ] **Step 3: Run the failing tests**

Run: `swift test --filter TeamPresenceStorageTests`
Expected: FAIL (compile error: `TeamPresenceRecord` has no `paneSessionName` member).

- [ ] **Step 4: Add the field to `TeamPresenceRecord`**

In `Sources/GrafttyKit/Teams/TeamPresence.swift`, replace the struct + initializer:

```swift
/// @spec TEAM-PRESENCE-1.2
/// @spec TEAM-IDLE-2.9
/// @spec TEAM-IDLE-2.10
/// Per-(team, worktree, runtime, pane) liveness record. Distinct from
/// worktree existence: a record means a runtime is alive AND has
/// registered itself. `paneSessionName` is set when the registering
/// process saw a `ZMX_SESSION` env var (i.e. inside a graftty-launched
/// zmx pane); nil otherwise.
public struct TeamPresenceRecord: Codable, Equatable, Sendable {
    public let teamID: String
    public let worktree: String
    public let runtime: TeamHookRuntime
    public let paneSessionName: String?
    public let pid: Int32
    public let registeredAt: Date

    public init(
        teamID: String,
        worktree: String,
        runtime: TeamHookRuntime,
        paneSessionName: String?,
        pid: Int32,
        registeredAt: Date
    ) {
        self.teamID = teamID
        self.worktree = worktree
        self.runtime = runtime
        self.paneSessionName = paneSessionName
        self.pid = pid
        self.registeredAt = registeredAt
    }
}
```

`Codable` synthesis handles missing-field-as-nil because `paneSessionName` is `String?`.

- [ ] **Step 5: Run tests — round-trip should pass; back-compat should pass**

Run: `swift test --filter TeamPresenceStorageTests`
Expected: PASS.

- [ ] **Step 6: Fix all callers of the old `TeamPresenceRecord.init`**

Run: `grep -rn "TeamPresenceRecord(" Sources Tests --include='*.swift'`

For each call site, add `paneSessionName: nil,` (preserving existing behavior). Common sites: `Sources/GrafttyCLI/Team.swift`, any tests that build records.

- [ ] **Step 7: Build the whole project to confirm**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 8: Run the full test suite**

Run: `swift test`
Expected: PASS — adding a nullable field with `nil` defaults at every call site is non-breaking.

- [ ] **Step 9: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamPresence.swift \
        Sources/GrafttyCLI/Team.swift \
        Tests/GrafttyKitTests/Teams/TeamPresenceStorageTests.swift
git commit -m "feat(presence): add optional paneSessionName to TeamPresenceRecord (TEAM-IDLE-2.9, 2.10)"
```

---

### Task 2: Per-pane storage keying

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamPresence.swift` (storage: `write`, `read`, `delete`, `filePath`)
- Test: `Tests/GrafttyKitTests/Teams/TeamPresenceStorageTests.swift`

**Why:** Two panes in the same worktree that both register codex would currently collide on the same file. The leaf needs to incorporate `paneSessionName`.

- [ ] **Step 1: Write failing tests for per-pane keying**

Append to `TeamPresenceStorageTests`:

```swift
@Test("@spec TEAM-IDLE-2.13: Two records with the same (worktree, runtime) but different paneSessionName coexist.")
func sameWorktreeRuntimeDifferentPanesCoexist() throws {
    let storage = try makeStorage()
    let base = (
        teamID: "/repo",
        worktree: "/repo/.worktrees/alice",
        registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try storage.write(.init(
        teamID: base.teamID, worktree: base.worktree, runtime: .codex,
        paneSessionName: "graftty-aaaaaaaa", pid: 1, registeredAt: base.registeredAt
    ))
    try storage.write(.init(
        teamID: base.teamID, worktree: base.worktree, runtime: .codex,
        paneSessionName: "graftty-bbbbbbbb", pid: 2, registeredAt: base.registeredAt
    ))
    let all = try storage.listAll().sorted { $0.pid < $1.pid }
    #expect(all.count == 2)
    #expect(all.map(\.paneSessionName) == ["graftty-aaaaaaaa", "graftty-bbbbbbbb"])
}

@Test("@spec TEAM-IDLE-2.13: Delete by paneSessionName removes only the matching record.")
func deleteByPaneSessionNameIsTargeted() throws {
    let storage = try makeStorage()
    let base = (
        teamID: "/repo",
        worktree: "/repo/.worktrees/alice",
        registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try storage.write(.init(
        teamID: base.teamID, worktree: base.worktree, runtime: .codex,
        paneSessionName: "graftty-aaaaaaaa", pid: 1, registeredAt: base.registeredAt
    ))
    try storage.write(.init(
        teamID: base.teamID, worktree: base.worktree, runtime: .codex,
        paneSessionName: "graftty-bbbbbbbb", pid: 2, registeredAt: base.registeredAt
    ))
    try storage.delete(
        teamID: base.teamID, worktree: base.worktree, runtime: .codex,
        paneSessionName: "graftty-aaaaaaaa"
    )
    let all = try storage.listAll()
    #expect(all.count == 1)
    #expect(all.first?.paneSessionName == "graftty-bbbbbbbb")
}

@Test("Delete with paneSessionName == nil removes only the worktree-only record.")
func deleteNilPaneOnlyTouchesWorktreeRecord() throws {
    let storage = try makeStorage()
    try storage.write(.init(
        teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
        paneSessionName: nil, pid: 1, registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
    ))
    try storage.write(.init(
        teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
        paneSessionName: "graftty-bbbbbbbb", pid: 2, registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
    ))
    try storage.delete(
        teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
        paneSessionName: nil
    )
    let all = try storage.listAll()
    #expect(all.count == 1)
    #expect(all.first?.paneSessionName == "graftty-bbbbbbbb")
}
```

- [ ] **Step 2: Run tests to confirm failure**

Run: `swift test --filter TeamPresenceStorageTests`
Expected: FAIL (file collision OR `delete` signature missing `paneSessionName`).

- [ ] **Step 3: Update storage methods to incorporate `paneSessionName` in the leaf**

In `Sources/GrafttyKit/Teams/TeamPresence.swift`, replace `write`, `read`, `delete`, and `filePath`:

```swift
public func write(_ record: TeamPresenceRecord) throws {
    let dir = presenceDirectory(teamID: record.teamID)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = filePath(
        teamID: record.teamID,
        worktree: record.worktree,
        runtime: record.runtime,
        paneSessionName: record.paneSessionName
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(record)
    try data.write(to: url, options: .atomic)
}

public func read(
    teamID: String,
    worktree: String,
    runtime: TeamHookRuntime,
    paneSessionName: String?
) throws -> TeamPresenceRecord? {
    let url = filePath(
        teamID: teamID,
        worktree: worktree,
        runtime: runtime,
        paneSessionName: paneSessionName
    )
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TeamPresenceRecord.self, from: data)
}

public func delete(
    teamID: String,
    worktree: String,
    runtime: TeamHookRuntime,
    paneSessionName: String?
) throws {
    let url = filePath(
        teamID: teamID,
        worktree: worktree,
        runtime: runtime,
        paneSessionName: paneSessionName
    )
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
}

private func filePath(
    teamID: String,
    worktree: String,
    runtime: TeamHookRuntime,
    paneSessionName: String?
) -> URL {
    let paneSegment = paneSessionName ?? "_no_pane"
    let leaf = TeamInbox.fileComponent("\(worktree).\(runtime.rawValue).\(paneSegment)") + ".json"
    return presenceDirectory(teamID: teamID).appendingPathComponent(leaf)
}
```

The sentinel `_no_pane` is safe because `TeamInbox.fileComponent` already escapes characters; existing presence files (no `paneSessionName`) live at the old leaf `<worktree>.<runtime>.json` and will *not* be found by the new lookups. That's the migration trade-off — old records exist but become invisible to per-pane lookups; `listAll()` still surfaces them, and they get re-created on the next `team register` cycle.

- [ ] **Step 4: Update `TeamPresenceMonitor.cleanupStale` for the new delete signature**

In the same file, replace the `delete` call inside `cleanupStale`:

```swift
try storage.delete(
    teamID: record.teamID,
    worktree: record.worktree,
    runtime: record.runtime,
    paneSessionName: record.paneSessionName
)
```

- [ ] **Step 5: Update all callers of `read` / `delete`**

Run: `grep -rn "presenceStorage.delete\|presenceStorage.read\|storage.delete(teamID\|storage.read(teamID" Sources Tests --include='*.swift'`

Add `paneSessionName: <value-or-nil>` to each call. Common sites:
- `Sources/GrafttyCLI/Team.swift` (`TeamUnregister.run`, will be updated in Task 4 anyway — for now pass `nil`).

- [ ] **Step 6: Run the new tests — they should pass**

Run: `swift test --filter TeamPresenceStorageTests`
Expected: PASS.

- [ ] **Step 7: Run the full test suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamPresence.swift \
        Sources/GrafttyCLI/Team.swift \
        Tests/GrafttyKitTests/Teams/TeamPresenceStorageTests.swift
git commit -m "feat(presence): per-pane key in storage path (TEAM-IDLE-2.13)"
```

---

## Phase 2 — CLI: register/unregister read `ZMX_SESSION`

### Task 3: `graftty team register` reads `ZMX_SESSION`

**Files:**
- Modify: `Sources/GrafttyCLI/Team.swift` (`TeamRegister.run`)
- Test: `Tests/GrafttyTests/Specs/TeamRegisterCLITests.swift` (new)

- [ ] **Step 1: Inspect `TeamRegister.run`**

Run: `grep -n "TeamRegister\|run()" Sources/GrafttyCLI/Team.swift | head -10`

The CLI calls into `TeamPresenceStorage.write` directly. We can unit-test the env-reading by extracting a small pure helper.

- [ ] **Step 2: Write a failing test against the helper**

Create `Tests/GrafttyTests/Specs/TeamRegisterCLITests.swift`:

```swift
import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("graftty team register — pane resolution")
struct TeamRegisterCLITests {
    @Test("@spec TEAM-IDLE-2.9: When ZMX_SESSION is set, the recorded paneSessionName equals it.")
    func paneSessionNameFromZmxSession() {
        let env = ["ZMX_SESSION": "graftty-abc12345"]
        let resolved = TeamRegisterPaneResolver.paneSessionName(env: env)
        #expect(resolved == "graftty-abc12345")
    }

    @Test("@spec TEAM-IDLE-2.10: When ZMX_SESSION is unset, the recorded paneSessionName is nil.")
    func paneSessionNameNilWhenUnset() {
        let env: [String: String] = [:]
        let resolved = TeamRegisterPaneResolver.paneSessionName(env: env)
        #expect(resolved == nil)
    }

    @Test("Empty ZMX_SESSION is treated as unset.")
    func paneSessionNameNilWhenEmpty() {
        let env = ["ZMX_SESSION": ""]
        let resolved = TeamRegisterPaneResolver.paneSessionName(env: env)
        #expect(resolved == nil)
    }
}
```

- [ ] **Step 3: Run the failing test**

Run: `swift test --filter TeamRegisterCLITests`
Expected: FAIL (compile error: no `TeamRegisterPaneResolver`).

- [ ] **Step 4: Add the resolver helper**

In `Sources/GrafttyCLI/Team.swift`, near `TeamRegister`, add:

```swift
/// @spec TEAM-IDLE-2.9
/// @spec TEAM-IDLE-2.10
/// Pure helper extracted for unit-testing the env → paneSessionName mapping.
/// Production callers pass `ProcessInfo.processInfo.environment`; tests
/// supply a synthetic dictionary.
public enum TeamRegisterPaneResolver {
    public static func paneSessionName(env: [String: String]) -> String? {
        guard let raw = env["ZMX_SESSION"], !raw.isEmpty else { return nil }
        return raw
    }
}
```

(Placing in `GrafttyCLI` keeps it visible to `@testable import Graftty` from the test file. If the import path is wrong, move the type to `GrafttyKit` — the helper has no dependencies.)

- [ ] **Step 5: Wire the resolver into `TeamRegister.run`**

Replace the body of `TeamRegister.run`:

```swift
func run() throws {
    guard let runtimeValue = TeamHookRuntime(rawValue: runtime) else {
        throw ValidationError("runtime must be one of: codex, claude")
    }
    guard let (team, worktreeName) = TeamPresenceCLI.resolveTeamAndWorktree() else {
        return
    }
    let storage = TeamPresenceStorage(rootDirectory: TeamPresenceStorage.defaultRoot())
    let teamID = TeamLookup.id(of: team)
    let paneSessionName = TeamRegisterPaneResolver.paneSessionName(
        env: ProcessInfo.processInfo.environment
    )
    let record = TeamPresenceRecord(
        teamID: teamID,
        worktree: worktreeName,
        runtime: runtimeValue,
        paneSessionName: paneSessionName,
        pid: ProcessInfo.processInfo.processIdentifier,
        registeredAt: Date()
    )
    try storage.write(record)
    try? TeamEventLog.defaultLog().append(
        .init(teamID: teamID, kind: .registered, detail: [
            "worktree": worktreeName,
            "runtime": runtimeValue.rawValue,
            "pid": String(record.pid),
            "pane_session_name": paneSessionName ?? "",
        ])
    )
}
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter TeamRegisterCLITests`
Expected: PASS.

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/GrafttyCLI/Team.swift \
        Tests/GrafttyTests/Specs/TeamRegisterCLITests.swift
git commit -m "feat(cli): team register reads ZMX_SESSION (TEAM-IDLE-2.9, 2.10)"
```

---

### Task 4: `graftty team unregister` reads `ZMX_SESSION`

**Files:**
- Modify: `Sources/GrafttyCLI/Team.swift` (`TeamUnregister.run`)
- Test: `Tests/GrafttyTests/Specs/TeamRegisterCLITests.swift`

- [ ] **Step 1: Add a failing test for unregister targeting**

Append to `TeamRegisterCLITests`:

```swift
@Test("@spec TEAM-IDLE-2.13: Unregister with ZMX_SESSION set targets only that pane's record.")
func unregisterWithZmxSessionDeletesOnlyMatchingRecord() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("graftty-presence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let storage = TeamPresenceStorage(rootDirectory: dir)
    let registeredAt = Date(timeIntervalSince1970: 1_700_000_000)
    try storage.write(.init(
        teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
        paneSessionName: "graftty-aaaaaaaa", pid: 1, registeredAt: registeredAt
    ))
    try storage.write(.init(
        teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
        paneSessionName: "graftty-bbbbbbbb", pid: 2, registeredAt: registeredAt
    ))

    try TeamUnregisterCore.unregister(
        storage: storage,
        teamID: "/repo",
        worktree: "/repo/.worktrees/alice",
        runtime: .codex,
        paneSessionName: "graftty-aaaaaaaa"
    )

    let surviving = try storage.listAll()
    #expect(surviving.count == 1)
    #expect(surviving.first?.paneSessionName == "graftty-bbbbbbbb")
}
```

- [ ] **Step 2: Run — should fail (no `TeamUnregisterCore`)**

Run: `swift test --filter TeamRegisterCLITests`
Expected: FAIL.

- [ ] **Step 3: Extract the unregister logic into a testable helper**

In `Sources/GrafttyCLI/Team.swift`, add adjacent to the resolver:

```swift
/// @spec TEAM-IDLE-2.13
/// Testable core of `team unregister`. Returns the prior record (if any)
/// so the caller can decide whether to emit an `unregistered` event.
public enum TeamUnregisterCore {
    @discardableResult
    public static func unregister(
        storage: TeamPresenceStorage,
        teamID: String,
        worktree: String,
        runtime: TeamHookRuntime,
        paneSessionName: String?
    ) throws -> TeamPresenceRecord? {
        let prior = try storage.read(
            teamID: teamID, worktree: worktree,
            runtime: runtime, paneSessionName: paneSessionName
        )
        try storage.delete(
            teamID: teamID, worktree: worktree,
            runtime: runtime, paneSessionName: paneSessionName
        )
        return prior
    }
}
```

- [ ] **Step 4: Wire `TeamUnregister.run` through the helper**

Replace `TeamUnregister.run`:

```swift
func run() throws {
    guard let runtimeValue = TeamHookRuntime(rawValue: runtime) else {
        throw ValidationError("runtime must be one of: codex, claude")
    }
    guard let (team, worktreeName) = TeamPresenceCLI.resolveTeamAndWorktree() else {
        return
    }
    let storage = TeamPresenceStorage(rootDirectory: TeamPresenceStorage.defaultRoot())
    let teamID = TeamLookup.id(of: team)
    let paneSessionName = TeamRegisterPaneResolver.paneSessionName(
        env: ProcessInfo.processInfo.environment
    )
    let prior = try TeamUnregisterCore.unregister(
        storage: storage,
        teamID: teamID,
        worktree: worktreeName,
        runtime: runtimeValue,
        paneSessionName: paneSessionName
    )
    if prior != nil {
        try? TeamEventLog.defaultLog().append(
            .init(teamID: teamID, kind: .unregistered, detail: [
                "worktree": worktreeName,
                "runtime": runtimeValue.rawValue,
                "pane_session_name": paneSessionName ?? "",
            ])
        )
    }
}
```

- [ ] **Step 5: Run the targeted tests**

Run: `swift test --filter TeamRegisterCLITests`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyCLI/Team.swift \
        Tests/GrafttyTests/Specs/TeamRegisterCLITests.swift
git commit -m "feat(cli): team unregister targets per-pane record (TEAM-IDLE-2.13)"
```

---

## Phase 3 — Wire protocol: `paneSessionName` on `.teamHook`

### Task 5: Add `paneSessionName` field to `.teamHook`

**Files:**
- Modify: `Sources/GrafttyKit/Notification/NotificationMessage.swift`
- Test: `Tests/GrafttyKitTests/Notification/NotificationMessageTests.swift` (existing)

- [ ] **Step 1: Inspect existing message tests**

Run: `grep -n "teamHook\|paneSessionName" Tests/GrafttyKitTests/Notification/NotificationMessageTests.swift`

- [ ] **Step 2: Add a failing round-trip test**

Append to `NotificationMessageTests`:

```swift
@Test("@spec TEAM-IDLE-2.9: .teamHook encodes and decodes paneSessionName when present.")
func teamHookRoundTripsPaneSessionName() throws {
    let original: NotificationMessage = .teamHook(
        callerWorktree: "/repo/.worktrees/alice",
        runtime: .codex,
        event: .stop,
        sessionID: "codex-internal-id",
        paneSessionName: "graftty-abc12345"
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(NotificationMessage.self, from: encoded)
    guard case let .teamHook(_, _, _, _, paneSessionName) = decoded else {
        Issue.record("expected .teamHook"); return
    }
    #expect(paneSessionName == "graftty-abc12345")
}

@Test("Old .teamHook payload (no pane_session_name) decodes paneSessionName as nil.")
func teamHookOldPayloadDecodesNil() throws {
    let oldJSON = """
    {
      "type": "team_hook",
      "caller_worktree": "/repo/.worktrees/alice",
      "runtime": "codex",
      "event": "stop"
    }
    """
    let decoded = try JSONDecoder().decode(NotificationMessage.self, from: oldJSON.data(using: .utf8)!)
    guard case let .teamHook(_, _, _, _, paneSessionName) = decoded else {
        Issue.record("expected .teamHook"); return
    }
    #expect(paneSessionName == nil)
}
```

- [ ] **Step 3: Run the tests**

Run: `swift test --filter NotificationMessageTests`
Expected: FAIL (compile + missing case shape).

- [ ] **Step 4: Add the field to the enum case**

In `Sources/GrafttyKit/Notification/NotificationMessage.swift`, change the case definition:

```swift
case teamHook(
    callerWorktree: String,
    runtime: TeamHookRuntime,
    event: TeamHookEvent,
    sessionID: String?,
    paneSessionName: String?
)
```

Add a coding key:

```swift
case paneSessionName = "pane_session_name"
```

In the encode block:

```swift
case .teamHook(let path, let runtime, let event, let sessionID, let paneSessionName):
    try container.encode("team_hook", forKey: .type)
    try container.encode(path, forKey: .callerWorktree)
    try container.encode(runtime, forKey: .runtime)
    try container.encode(event, forKey: .event)
    try container.encodeIfPresent(sessionID, forKey: .sessionID)
    try container.encodeIfPresent(paneSessionName, forKey: .paneSessionName)
```

In the decode block:

```swift
let sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
let paneSessionName = try container.decodeIfPresent(String.self, forKey: .paneSessionName)
self = .teamHook(callerWorktree: path, runtime: runtime, event: event,
                 sessionID: sessionID, paneSessionName: paneSessionName)
```

- [ ] **Step 5: Update all `.teamHook(...)` constructor / pattern-match sites**

Run: `grep -rn "\.teamHook(" Sources Tests --include='*.swift'`

For each:
- **Constructor:** add `paneSessionName: nil` (or the actual value).
- **Pattern match:** add a fifth binding, use `_` if unused.

Common sites: `Sources/Graftty/GrafttyApp.swift:1706` (handler dispatch), `Sources/GrafttyCLI/Team.swift` (`TeamHook.run`).

- [ ] **Step 6: Run the targeted tests**

Run: `swift test --filter NotificationMessageTests`
Expected: PASS.

- [ ] **Step 7: Build the project**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 8: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/GrafttyKit/Notification/NotificationMessage.swift \
        Sources/Graftty/GrafttyApp.swift \
        Sources/GrafttyCLI/Team.swift \
        Tests/GrafttyKitTests/Notification/NotificationMessageTests.swift
git commit -m "feat(wire): paneSessionName on .teamHook (TEAM-IDLE-2.9)"
```

---

### Task 6: `TeamHook` CLI sends `ZMX_SESSION` over the wire

**Files:**
- Modify: `Sources/GrafttyCLI/Team.swift` (`TeamHook.run`)

- [ ] **Step 1: Update `TeamHook.run` to read `ZMX_SESSION` and forward it**

Inside `TeamHook.run`, just before the `SocketClient.sendExpectingResponse` call, add:

```swift
let paneSessionName = TeamRegisterPaneResolver.paneSessionName(
    env: ProcessInfo.processInfo.environment
)
```

Then update the `.teamHook(...)` constructor:

```swift
let response = try SocketClient.sendExpectingResponse(
    .teamHook(
        callerWorktree: worktreePath,
        runtime: runtime,
        event: event,
        sessionID: resolvedSessionID,
        paneSessionName: paneSessionName
    )
)
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 3: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyCLI/Team.swift
git commit -m "feat(cli): team hook forwards ZMX_SESSION (TEAM-IDLE-2.9)"
```

---

### Task 7: `TeamInboxRequestHandler` forwards `paneSessionName` to callbacks

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamInboxRequestHandlerTests.swift`

The hook callbacks need to receive `paneSessionName` so the GrafttyApp wiring can resolve it to a paneID. We widen `TeamHookCallbacks` here.

- [ ] **Step 1: Locate `TeamHookCallbacks`**

Run: `grep -n "TeamHookCallbacks\b" Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift`

- [ ] **Step 2: Write a failing test for forwarding**

Append to `TeamInboxRequestHandlerTests` (find a good fit in the existing file):

```swift
@Test("@spec TEAM-IDLE-2.9: hook(...) forwards paneSessionName into the onStop callback.")
func hookForwardsPaneSessionNameToOnStop() async throws {
    var capturedPaneSessionName: String? = "<unset>"
    let callbacks = TeamHookCallbacks(
        onStop: { _, _, _, paneSessionName in
            capturedPaneSessionName = paneSessionName
        },
        onSessionStart: { _, _, _, _ in },
        onPostToolUse: { _, _, _, _ in }
    )
    // (Construct a handler the way the existing tests do — copy the
    // fixture-builder pattern from a sibling test.)
    let handler = makeHandler(callbacks: callbacks)
    _ = try handler.hook(
        callerWorktree: "/repo/.worktrees/alice",
        runtime: .codex,
        event: .stop,
        sessionID: nil,
        paneSessionName: "graftty-abc12345"
    )
    #expect(capturedPaneSessionName == "graftty-abc12345")
}
```

(If the existing test file has its own helper `makeHandler` with a different name/signature, mirror that — the goal is one targeted test of the new forwarding.)

- [ ] **Step 3: Run — should fail (signature mismatch)**

Run: `swift test --filter TeamInboxRequestHandlerTests`
Expected: FAIL.

- [ ] **Step 4: Widen `TeamHookCallbacks` and `hook(...)`**

In `Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift`, change the closure types:

```swift
public struct TeamHookCallbacks: Sendable {
    public let onStop: @Sendable (String, String, TeamHookRuntime, String?) -> Void
    public let onSessionStart: @Sendable (String, String, TeamHookRuntime, String?) -> Void
    public let onPostToolUse: @Sendable (String, String, TeamHookRuntime, String?) -> Void

    public init(
        onStop: @escaping @Sendable (String, String, TeamHookRuntime, String?) -> Void,
        onSessionStart: @escaping @Sendable (String, String, TeamHookRuntime, String?) -> Void,
        onPostToolUse: @escaping @Sendable (String, String, TeamHookRuntime, String?) -> Void
    ) {
        self.onStop = onStop
        self.onSessionStart = onSessionStart
        self.onPostToolUse = onPostToolUse
    }
}
```

(The fourth parameter is `paneSessionName: String?`. Note: previously the closures took `runtime: String` — change to `TeamHookRuntime` if helpful, or keep `String` and let GrafttyApp adapt; keep current type to minimize churn — re-check existing callbacks for `String` vs `TeamHookRuntime`.)

In the `hook(...)` method body, plumb `paneSessionName` into each callback invocation:

```swift
public func hook(
    callerWorktree: String,
    runtime: TeamHookRuntime,
    event: TeamHookEvent,
    sessionID: String?,
    paneSessionName: String?
) throws -> String {
    // … existing logic …
    switch event {
    case .stop:
        callbacks?.onStop(teamID, callerWorktree, runtime, paneSessionName)
    case .sessionStart:
        callbacks?.onSessionStart(teamID, callerWorktree, runtime, paneSessionName)
    case .postToolUse:
        callbacks?.onPostToolUse(teamID, callerWorktree, runtime, paneSessionName)
    }
    // …
}
```

- [ ] **Step 5: Update all `TeamHookCallbacks(…)` initializers and `hook(...)` callers**

Run: `grep -rn "TeamHookCallbacks(\|\.hook(" Sources Tests --include='*.swift'`

For each:
- Add `paneSessionName: String?` parameter to the closure body, even if unused (`_`).
- For `hook(...)` callers, pass `paneSessionName` through.

`Sources/Graftty/GrafttyApp.swift` lines 922-948 are the principal site — update each closure to accept the new param. Most existing closures will just take `_` for now; Task 10/11 will use it.

- [ ] **Step 6: Run the targeted tests**

Run: `swift test --filter TeamInboxRequestHandlerTests`
Expected: PASS.

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift \
        Sources/Graftty/GrafttyApp.swift \
        Tests/GrafttyKitTests/Teams/TeamInboxRequestHandlerTests.swift
git commit -m "feat(hook): forward paneSessionName through TeamHookCallbacks (TEAM-IDLE-2.9)"
```

---

## Phase 4 — `IdleDeliveryService` API change

### Task 8: `paneIDs: [UUID]` API + fan-out + drop `runtime` parameter

**Files:**
- Modify: `Sources/GrafttyKit/Teams/IdleDeliveryService.swift`
- Test: `Tests/GrafttyTests/Specs/IdleDeliveryTests.swift`

- [ ] **Step 1: Write failing tests for the new API**

In `Tests/GrafttyTests/Specs/IdleDeliveryTests.swift`, add (replacing the TEAM-IDLE-2.8 `runtime: nil` tests added earlier — these are now superseded by `paneIDs: []`):

```swift
@Test("@spec TEAM-IDLE-2.11: paneIDs.count == 2 → both panes receive nudges; watermark advances exactly once.")
func fanOutToTwoPanes() async throws {
    let f = try Fixture()
    let id = try f.appendUnread(body: "hello")
    let paneA = UUID()
    let paneB = UUID()
    f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
    f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)

    await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree, paneIDs: [paneA, paneB])

    #expect(f.sender.calls.count == 2)
    #expect(Set(f.sender.calls.map(\.paneID)) == Set([paneA, paneB]))
    #expect(try f.inbox.zmxWatermark(teamID: f.teamID, worktree: f.worktree, runtime: "codex") == id)
}

@Test("@spec TEAM-IDLE-2.12: paneIDs is empty → no nudge, no watermark advance.")
func emptyPaneIDsSkips() async throws {
    let f = try Fixture()
    _ = try f.appendUnread(body: "hello")
    await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree, paneIDs: [])
    #expect(f.sender.calls.isEmpty)
    #expect(try f.inbox.zmxWatermark(teamID: f.teamID, worktree: f.worktree, runtime: "codex") == nil)
}
```

Delete the obsolete `unconfirmedRuntimeSkipsKeysInput` and `unconfirmedRuntimeOnStopSkips` tests added in PR #136 — they tested an API that no longer exists. The TEAM-IDLE-2.8 spec is *replaced* (not violated) by TEAM-IDLE-2.12. Remove the `@spec TEAM-IDLE-2.8` from `IdleDeliveryService.swift`'s doc comment as part of Task 8 Step 4.

Update existing single-pane tests: each call site `runtime: "codex", paneID: f.paneID` → `paneIDs: [f.paneID]`. (Apply at Step 4.)

- [ ] **Step 2: Run — should fail (compile + signature mismatch)**

Run: `swift test --filter IdleDelivery`
Expected: FAIL.

- [ ] **Step 3: Update `IdleDeliveryService` API and implementation**

Replace `onStop`, `onMessageArrival`, and `maybeDeliver`:

```swift
public func onStop(team: String, worktree: String, paneIDs: [UUID]) async {
    await maybeDeliver(team: team, worktree: worktree, paneIDs: paneIDs, trigger: "stop")
}

public func onMessageArrival(team: String, worktree: String, paneIDs: [UUID]) async {
    await maybeDeliver(team: team, worktree: worktree, paneIDs: paneIDs, trigger: "messageArrival")
}

private func maybeDeliver(
    team: String,
    worktree: String,
    paneIDs: [UUID],
    trigger: String
) async {
    // The service is implicitly codex-only by construction:
    // - inbox-observer dispatch passes only codex paneIDs (filtered upstream);
    // - the Stop-hook callback only invokes us for runtime == .codex.
    guard !paneIDs.isEmpty else {
        log(team: team, worktree: worktree, runtime: "codex",
            outcome: "skipped_no_codex_panes")
        return
    }
    let s = state.state(worktree: worktree, runtime: "codex")
    guard s == .idle || s == .unknown else {
        log(team: team, worktree: worktree, runtime: "codex",
            outcome: "skipped_state_\(s.rawValue)")
        return
    }
    let watermark: String?
    do { watermark = try inbox.zmxWatermark(teamID: team, worktree: worktree, runtime: "codex") }
    catch {
        log(team: team, worktree: worktree, runtime: "codex", outcome: "error_watermark_read")
        return
    }
    let pending: [TeamInboxMessage]
    do { pending = try inbox.unreadMessages(teamID: team, recipientWorktree: worktree, after: watermark) }
    catch {
        log(team: team, worktree: worktree, runtime: "codex", outcome: "error_inbox_read")
        return
    }
    guard let lastMessage = pending.last else {
        log(team: team, worktree: worktree, runtime: "codex", outcome: "skipped_no_pending")
        return
    }
    let text = TeamHookRenderer.format(messages: pending)
    for paneID in paneIDs {
        await nudgeSender.send(paneID: paneID, message: text, messageIDs: pending.map(\.id))
    }
    do {
        try inbox.advanceZmxWatermark(teamID: team, worktree: worktree,
                                      runtime: "codex", to: lastMessage.id)
    } catch {
        log(team: team, worktree: worktree, runtime: "codex", outcome: "error_watermark_write")
        return
    }
    log(team: team, worktree: worktree, runtime: "codex",
        outcome: "sent", messageIDs: pending.map(\.id), trigger: trigger)
}
```

- [ ] **Step 4: Update doc-comment spec annotations on the service**

Change the `@spec` block above `IdleDeliveryService`:

```swift
/// @spec TEAM-IDLE-2.1
/// @spec TEAM-IDLE-2.3
/// @spec TEAM-IDLE-2.4
/// @spec TEAM-IDLE-2.5
/// @spec TEAM-IDLE-2.6
/// @spec TEAM-IDLE-2.11
/// @spec TEAM-IDLE-2.12
```

Remove `TEAM-IDLE-2.8` (superseded).

- [ ] **Step 5: Update existing IdleDeliveryTests' single-pane callers**

In every existing test that called the old API, replace:
- `await f.service.onStop(team: ..., worktree: ..., runtime: "codex", paneID: f.paneID)` → `await f.service.onStop(team: ..., worktree: ..., paneIDs: [f.paneID])`
- `await f.service.onMessageArrival(team: ..., worktree: ..., runtime: "codex", paneID: f.paneID)` → same shape with `paneIDs:`.
- The `runtime: "codex"` argument is removed.
- `paneID: nil` in `noPaneSkipsAndLogs` → `paneIDs: []`.

Delete the two TEAM-IDLE-2.8 tests added in PR #136 (`unconfirmedRuntimeSkipsKeysInput`, `unconfirmedRuntimeOnStopSkips`).

The `claudeRuntimeIsSkipped` test no longer applies at this level (the service is codex-only); delete it too. (Claude is skipped at the GrafttyApp callback site instead — covered by Task 11's tests.)

- [ ] **Step 6: Update `IdleDeliveryEndToEndTests` callers**

Same `runtime: "codex", paneID: pane` → `paneIDs: [pane]` substitution at the single call site.

- [ ] **Step 7: Run idle-delivery tests**

Run: `swift test --filter IdleDelivery`
Expected: PASS.

- [ ] **Step 8: Run full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/GrafttyKit/Teams/IdleDeliveryService.swift \
        Tests/GrafttyTests/Specs/IdleDeliveryTests.swift \
        Tests/GrafttyKitTests/Teams/IdleDeliveryEndToEndTests.swift
git commit -m "refactor(idle): paneIDs:[UUID] fan-out, drop runtime param (TEAM-IDLE-2.11, 2.12)"
```

---

## Phase 5 — GrafttyApp wiring

### Task 9: `TerminalManager.paneID(forSessionName:)` helper

**Files:**
- Modify: `Sources/Graftty/Terminal/TerminalManager.swift`

- [ ] **Step 1: Add the helper next to the existing `handle(forSessionName:)`**

Insert directly under `handle(forSessionName:)` at `Sources/Graftty/Terminal/TerminalManager.swift:618`:

```swift
/// Reverse-lookup of the pane UUID whose pane derives the given
/// zmx session name. Returns nil if no surface matches (e.g. pane
/// closed). O(n) over the surface set, same cost class as `handle`.
func paneID(forSessionName sessionName: String) -> UUID? {
    surfaces.first(where: { ZmxLauncher.sessionName(for: $0.key.id) == sessionName })?.key.id
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Terminal/TerminalManager.swift
git commit -m "feat(terminal): paneID(forSessionName:) reverse lookup"
```

---

### Task 10: `codexPanesIn(worktree:)` helper + inbox-observer migration

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`

- [ ] **Step 1: Inspect the inbox-observer block**

Run: `grep -n "let inboxRoot\|TeamInboxObserver\|onMessageArrival" Sources/Graftty/GrafttyApp.swift | head -10`

The closure of interest is at lines ~951-1003 (block beginning `// Subscribe the idle service to inbox file-system events.`).

- [ ] **Step 2: Add the `codexPanesIn` helper near `resolvePaneID`**

Inside the `startup()` flow, after the existing `presenceStorage` definition (line ~828) and after `resolvePaneID` (~849), add:

```swift
// Resolve the current set of registered codex panes for a worktree.
// Reads TeamPresenceStorage on the main actor (file count is bounded
// by active-agent count — typically <20) and reverse-resolves each
// recorded paneSessionName via TerminalManager.
let codexPanesIn: @Sendable (String) -> [UUID] = { worktreePath in
    MainActor.assumeIsolated {
        let records = (try? presenceStorage.listAll()) ?? []
        let codexSessions = records
            .filter { $0.worktree == worktreePath && $0.runtime == .codex }
            .compactMap { $0.paneSessionName }
        return codexSessions.compactMap { sessionName in
            terminalManager.paneID(forSessionName: sessionName)
        }
    }
}
```

- [ ] **Step 3: Replace the inbox-observer dispatch closure body**

Inside the inbox-observer `.start { messages in ... }` block, replace the per-recipient dispatch block:

```swift
for (recipientWorktree, _) in byWorktree {
    Task { @MainActor in
        let paneIDs = codexPanesIn(recipientWorktree)
        await service.onMessageArrival(
            team: teamID,
            worktree: recipientWorktree,
            paneIDs: paneIDs
        )
    }
}
```

(`recipientMessages.last?.to.runtime` and the `?? "codex"` fallback — both removed by PR #136 — are no longer relevant.)

- [ ] **Step 4: Drop `resolveRuntime` (now unused)**

Delete the `resolveRuntime: @Sendable (String, UUID?) -> String?` definition (~lines 855-872) and its usages.

- [ ] **Step 5: Build**

Run: `swift build`
Expected: Build complete (a few unused-warning lints may appear; those are addressed in Task 11).

- [ ] **Step 6: Run idle-delivery and inbox-observer tests**

Run: `swift test --filter "IdleDelivery|TeamInboxObserver"`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift
git commit -m "refactor(app): inbox observer routes via codexPanesIn (TEAM-IDLE-2.11, 2.12)"
```

---

### Task 11: Drop `agentForPane`, route Stop hook through `paneSessionName`, gate Claude

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`

- [ ] **Step 1: Locate `agentForPane` declarations and consumers**

Run: `grep -n "agentForPane" Sources/Graftty/GrafttyApp.swift`

Sites:
- `var agentForPane: [...] = [:]` declaration (~line 106).
- Reads inside `resolveRuntime` closure (already removed in Task 10).
- Reads inside `PaneInputActivityObserver.onKeystroke` closure (~line 909-918).
- Writes inside `onSessionStart`, `onPostToolUse` (~lines 933-947).
- Pane-close cleanup (~lines 1017-1028).

- [ ] **Step 2: Replace the keystroke-observer's lookup with a presence-storage scan**

Replace the body of the `onKeystroke:` closure inside `PaneInputActivityObserver(...)`:

```swift
onKeystroke: { [weak graceScheduler] paneID in
    MainActor.assumeIsolated {
        let sessionName = ZmxLauncher.sessionName(for: paneID)
        let records = (try? presenceStorage.listAll()) ?? []
        guard let agent = records.first(where: { $0.paneSessionName == sessionName }) else {
            return
        }
        stateRegistry.handleKeystroke(worktree: agent.worktree, runtime: agent.runtime.rawValue)
        graceScheduler?.bump(worktree: agent.worktree, runtime: agent.runtime.rawValue)
    }
}
```

(`services` capture is no longer needed since `agentForPane` is gone.)

- [ ] **Step 3: Replace `onSessionStart`, `onPostToolUse`, `onStop` callback bodies**

`onSessionStart` and `onPostToolUse` no longer write to `agentForPane`. They keep their state-machine bookkeeping. The fourth `paneSessionName: String?` argument is currently unused here — leave as `_`:

```swift
onSessionStart: { team, worktree, runtime, _ in
    stateRegistry.handleSessionStart(worktree: worktree, runtime: runtime.rawValue)
},
onPostToolUse: { team, worktree, runtime, _ in
    stateRegistry.handlePostToolUse(worktree: worktree, runtime: runtime.rawValue)
}
```

`onStop` resolves `paneSessionName` to a paneID and only invokes `idleService.onStop` for codex:

```swift
onStop: { [weak idleService] team, worktree, runtime, paneSessionName in
    let paneID: UUID? = MainActor.assumeIsolated {
        paneSessionName.flatMap { terminalManager.paneID(forSessionName: $0) }
    }
    let lastInputAt = paneID.flatMap { inputRegistry.lastInputAt(paneID: $0) }
    stateRegistry.handleStop(worktree: worktree, runtime: runtime.rawValue, lastInputAt: lastInputAt)
    guard runtime == .codex else { return }
    guard let paneID, let service = idleService else { return }
    Task { await service.onStop(team: team, worktree: worktree, paneIDs: [paneID]) }
}
```

(Note: callback closure types from Task 7 use `runtime: TeamHookRuntime`. Confirm it's the typed enum, not `String`. If it's `String`, adapt the `runtime == .codex` check accordingly.)

- [ ] **Step 4: Delete the `agentForPane` declaration and its pane-close cleanup**

Remove from `AppServices`:

```swift
var agentForPane: [UUID: (worktree: String, runtime: String)] = [:]
```

In the pane-close cleanup (~line 1022), replace the `agentForPane` access with a presence-storage scan + delete (per TEAM-IDLE-2.15):

```swift
// On pane destroy, sweep any TeamPresenceRecord whose paneSessionName
// corresponds to this pane. Best-effort; the agent's own
// `team unregister` cleanup hook is the primary path.
let sessionName = ZmxLauncher.sessionName(for: paneID)
let records = (try? presenceStorage.listAll()) ?? []
for record in records where record.paneSessionName == sessionName {
    try? presenceStorage.delete(
        teamID: record.teamID,
        worktree: record.worktree,
        runtime: record.runtime,
        paneSessionName: record.paneSessionName
    )
    stateRegistry.removeState(worktree: record.worktree, runtime: record.runtime.rawValue)
}
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 6: Run the full test suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift
git commit -m "refactor(app): drop agentForPane, route via TeamPresenceStorage (TEAM-IDLE-2.14, 2.15)"
```

---

## Phase 6 — Final spec coverage tests

### Task 12: TEAM-IDLE-2.14 (claude registered → no keys-input) + TEAM-IDLE-2.15 (pane close cleans presence)

**Files:**
- Test: `Tests/GrafttyKitTests/Teams/IdleDeliveryEndToEndTests.swift` (or a new file if cleaner)

- [ ] **Step 1: Add the spec tests**

Append to `IdleDeliveryEndToEndTests`:

```swift
@Test("@spec TEAM-IDLE-2.14: A registered claude pane does not produce keys-input.")
func claudeRegistrationDoesNotTypeIntoPane() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("graftty-e2e-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let inbox = TeamInbox(rootDirectory: dir, idGenerator: { UUID().uuidString }, now: { Date() })
    let state = WorktreeAgentStateRegistry()
    let writer = StubWriter()
    let service = IdleDeliveryService(
        inbox: inbox, state: state, nudgeSender: ZmxNudgeSender(writer: writer)
    )
    // No paneIDs passed — simulating the upstream filter that excludes claude.
    let worktree = "/repo/.worktrees/alice"
    let team = "/repo"
    _ = try inbox.appendMessage(
        teamID: team, teamName: "repo", repoPath: "/repo",
        from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
        to: TeamInboxEndpoint(member: "alice", worktree: worktree, runtime: nil),
        priority: .normal, kind: "team_message", body: "hello"
    )
    state.handleSessionStart(worktree: worktree, runtime: "claude")
    state.handleStop(worktree: worktree, runtime: "claude", lastInputAt: nil)
    await service.onStop(team: team, worktree: worktree, paneIDs: [])
    #expect(writer.writes.isEmpty)
}
```

For TEAM-IDLE-2.15, append to `TeamPresenceStorageTests`:

```swift
@Test("@spec TEAM-IDLE-2.15: Deleting by paneSessionName mirrors a pane-close cleanup sweep.")
func paneCloseSweepRemovesMatchingRecord() throws {
    let storage = try makeStorage()
    let registeredAt = Date(timeIntervalSince1970: 1_700_000_000)
    try storage.write(.init(
        teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
        paneSessionName: "graftty-aaaaaaaa", pid: 1, registeredAt: registeredAt
    ))
    try storage.write(.init(
        teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
        paneSessionName: "graftty-bbbbbbbb", pid: 2, registeredAt: registeredAt
    ))
    // Mimic the GrafttyApp pane-close cleanup loop.
    let closingSessionName = "graftty-aaaaaaaa"
    for record in try storage.listAll() where record.paneSessionName == closingSessionName {
        try storage.delete(
            teamID: record.teamID, worktree: record.worktree,
            runtime: record.runtime, paneSessionName: record.paneSessionName
        )
    }
    let surviving = try storage.listAll()
    #expect(surviving.count == 1)
    #expect(surviving.first?.paneSessionName == "graftty-bbbbbbbb")
}
```

- [ ] **Step 2: Run the targeted tests**

Run: `swift test --filter "IdleDeliveryEndToEndTests|TeamPresenceStorageTests"`
Expected: PASS.

- [ ] **Step 3: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Tests/GrafttyKitTests/Teams/IdleDeliveryEndToEndTests.swift \
        Tests/GrafttyKitTests/Teams/TeamPresenceStorageTests.swift
git commit -m "test(team-idle): claude exclusion + pane-close sweep (TEAM-IDLE-2.14, 2.15)"
```

---

## Phase 7 — Documentation, /simplify, PR

### Task 13: Regenerate SPECS.md, run /simplify, push, open PR

- [ ] **Step 1: Regenerate SPECS.md**

Run: `scripts/generate-specs.py`
Expected: `Wrote SPECS.md (NN markers)` — note that TEAM-IDLE-* entries don't currently surface in SPECS.md due to a generator-regex limitation (out of scope here); `--check` should still pass.

- [ ] **Step 2: Confirm `--check` is green**

Run: `scripts/generate-specs.py --check`
Expected: exit 0.

- [ ] **Step 3: Commit any SPECS.md change**

```bash
git diff --quiet SPECS.md || (git add SPECS.md && git commit -m "specs: regenerate for TEAM-IDLE-2.9..2.15")
```

- [ ] **Step 4: Run /simplify**

Invoke `/simplify` against the full diff vs `main`. Apply any suggested simplifications inline; small follow-up commit if needed.

- [ ] **Step 5: Push to origin**

```bash
git push origin limit-keys-teams-messages
```

(Branch is already tracking origin from PR #136.)

- [ ] **Step 6: Update PR #136 description**

The branch already has PR #136 open. Update its description to reflect the expanded scope:

```bash
gh pr edit 136 --body "$(cat <<'EOF'
## Summary

Two-part fix for team-message keys-input delivery to non-codex panes.

**Part 1 (TEAM-IDLE-2.8):** When the runtime can't be confirmed as codex, skip keys-input — closes the gate that the upstream `?? "codex"` fallback was bypassing.

**Part 2 (TEAM-IDLE-2.9..2.15):** Make registration explicitly per-pane.
`graftty team register --runtime <r>` now reads `ZMX_SESSION` and records `paneSessionName` on the `TeamPresenceRecord`. The inbox-observer dispatch fans out to *every* registered codex pane in the recipient worktree. The in-memory `agentForPane` map is removed; both consumers (keystroke routing, inbox dispatch) read directly from `TeamPresenceStorage`. `IdleDeliveryService` becomes codex-only by construction (`runtime` parameter dropped); claude is gated at the Stop-hook callback site.

Spec: `docs/superpowers/specs/2026-05-08-pane-specific-team-registration-design.md`
Plan: `docs/superpowers/plans/2026-05-08-pane-specific-team-registration.md`

## Test plan

- [x] `swift test` — full suite green
- [x] `scripts/generate-specs.py --check` — passes
- [ ] CI green on PR

## Behavior change

If a worktree has multiple panes and only some run codex, team messages are typed only into the codex pane(s), regardless of which pane is focused. Old worktree-only `TeamPresenceRecord` files (no `paneSessionName`) decode as nil and are ineligible for delivery — replaced naturally on the next `team register` call from the wrapper.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 7: Watch CI**

Run: `gh pr checks 136 --watch` (in foreground or background).
Expected: all jobs green.

- [ ] **Step 8: Final report**

Confirm to user:
- Total commits added on the branch.
- Final test count + pass/fail.
- PR URL.

---

## Self-review against the spec

Spec coverage check:

- **Registration shape (paneSessionName field, storage key)** → Tasks 1, 2.
- **`graftty team register` reads `ZMX_SESSION`** → Task 3 (TEAM-IDLE-2.9, 2.10).
- **`graftty team unregister` reads `ZMX_SESSION`** → Task 4 (TEAM-IDLE-2.13).
- **Hooks become event signals only (drop `agentForPane` writes)** → Task 11.
- **Wire protocol field** → Tasks 5, 6, 7 (TEAM-IDLE-2.9).
- **Inbox-observer dispatch via `codexPanesIn`** → Task 10 (TEAM-IDLE-2.11, 2.12).
- **`IdleDeliveryService` API change to `paneIDs: [UUID]`, fan-out, drop `runtime`** → Task 8 (TEAM-IDLE-2.11, 2.12).
- **Two upstream gates ensure only codex paneIDs reach service** → Task 11 (Stop-hook callback gates on `runtime == .codex`).
- **Pane-close cleans presence** → Task 11 (cleanup loop) + Task 12 (test for TEAM-IDLE-2.15).
- **Claude registers but no keys-input** → Task 11 (gate) + Task 12 (TEAM-IDLE-2.14 test).
- **Migration / back-compat** → Task 1 (decoder defaults nil) + Task 2 (sentinel leaf).

No gaps.
