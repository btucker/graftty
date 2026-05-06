# Event-driven Codex idle delivery via zmx-send — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `IdleDeliveryService`'s polling-with-stub-NSLog with hook-event-driven idle detection that wires real zmx-send into the recipient worktree's first pane, gated by a libghostty-input-boundary keystroke observer.

**Architecture:** Per-worktree state machine (`unknown` → `active` ↔ `idle`/`user_engaged`) driven by Stop/SessionStart/PostToolUse hook events plus a process-wide `[PaneID: Date]` keystroke registry. Stop hook side-effect calls `IdleDeliveryService.onStop`. `TeamInboxObserver` already fires per-write events; service subscribes for `onMessageArrival`. No polling, no time-based staleness threshold.

**Tech Stack:** Swift, Swift Testing for new tests, XCTest for legacy. SwiftUI input observation via libghostty surface bindings.

**Spec:** `docs/superpowers/specs/2026-05-06-zmx-nudge-event-driven-idle-delivery-design.md`

---

## Task 1: Add `zmxWatermark` storage to `TeamInbox`

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamInbox.swift`
- Create: `Tests/GrafttyKitTests/Teams/TeamInboxZmxWatermarkTests.swift`

- [ ] **Step 1: Write failing tests for zmxWatermark read/advance**

```swift
// Tests/GrafttyKitTests/Teams/TeamInboxZmxWatermarkTests.swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamInbox.zmxWatermark — per-(team,worktree,runtime) read state for zmx delivery")
struct TeamInboxZmxWatermarkTests {
    @Test("Initial read returns nil for unknown key.")
    func initialNil() throws {
        let inbox = try Self.makeInbox()
        #expect(try inbox.zmxWatermark(teamID: "/r", worktree: "/r/alice", runtime: "codex") == nil)
    }

    @Test("Advance writes and read returns the most recent ID.")
    func advanceThenRead() throws {
        let inbox = try Self.makeInbox()
        try inbox.advanceZmxWatermark(teamID: "/r", worktree: "/r/alice", runtime: "codex", to: "msg-7")
        #expect(try inbox.zmxWatermark(teamID: "/r", worktree: "/r/alice", runtime: "codex") == "msg-7")
    }

    @Test("Watermarks are independent per (worktree, runtime).")
    func independentKeys() throws {
        let inbox = try Self.makeInbox()
        try inbox.advanceZmxWatermark(teamID: "/r", worktree: "/r/alice", runtime: "codex", to: "a-1")
        try inbox.advanceZmxWatermark(teamID: "/r", worktree: "/r/bob", runtime: "claude", to: "b-1")
        #expect(try inbox.zmxWatermark(teamID: "/r", worktree: "/r/alice", runtime: "codex") == "a-1")
        #expect(try inbox.zmxWatermark(teamID: "/r", worktree: "/r/bob", runtime: "claude") == "b-1")
        #expect(try inbox.zmxWatermark(teamID: "/r", worktree: "/r/alice", runtime: "claude") == nil)
    }

    private static func makeInbox() throws -> TeamInbox {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-zmx-watermark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TeamInbox(rootDirectory: dir, idGenerator: { UUID().uuidString }, now: { Date() })
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

```bash
swift test --filter "TeamInboxZmxWatermarkTests"
```
Expected: compile error (`zmxWatermark` and `advanceZmxWatermark` don't exist yet).

- [ ] **Step 3: Add zmxWatermark API to TeamInbox**

In `TeamInbox.swift`, alongside the existing `worktreeWatermark` API, add:

```swift
/// @spec TEAM-IDLE-2.6
/// Per-(team, worktree, runtime) cursor advanced after a successful
/// zmx-send delivery. Distinct from the per-session `cursor` (advanced
/// on hook delivery) and the per-worktree read watermark (advanced when
/// the user runs `graftty team inbox`). Three watermarks because each
/// tracks a different "the agent has seen this" semantic.
public func zmxWatermark(teamID: String, worktree: String, runtime: String) throws -> String? {
    let url = zmxWatermarkURL(teamID: teamID, worktree: worktree, runtime: runtime)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

public func advanceZmxWatermark(teamID: String, worktree: String, runtime: String, to messageID: String) throws {
    let url = zmxWatermarkURL(teamID: teamID, worktree: worktree, runtime: runtime)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try messageID.write(to: url, atomically: true, encoding: .utf8)
}

private func zmxWatermarkURL(teamID: String, worktree: String, runtime: String) -> URL {
    rootDirectory
        .appendingPathComponent(Self.fileComponent(teamID), isDirectory: true)
        .appendingPathComponent("zmx-watermarks", isDirectory: true)
        .appendingPathComponent("\(Self.fileComponent(worktree)).\(runtime)")
}
```

(If `Self.fileComponent` is `private`, expose it as `internal static` so this method can use it.)

- [ ] **Step 4: Run tests, expect pass**

```bash
swift test --filter "TeamInboxZmxWatermarkTests"
```
Expected: 3/3 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamInbox.swift Tests/GrafttyKitTests/Teams/TeamInboxZmxWatermarkTests.swift
git commit -m "feat(teams): add zmxWatermark API to TeamInbox

Per-(team, worktree, runtime) cursor advanced after zmx-send
delivery. Distinct from per-session cursor and per-worktree read
watermark — three watermarks because each tracks a different
'agent has seen this' semantic.

@spec TEAM-IDLE-2.6"
```

---

## Task 2: `WorktreeAgentStateRegistry` — pure state machine

**Files:**
- Create: `Sources/GrafttyKit/Teams/WorktreeAgentStateRegistry.swift`
- Create: `Tests/GrafttyKitTests/Teams/WorktreeAgentStateRegistryTests.swift`

- [ ] **Step 1: Write failing tests for state transitions**

```swift
// Tests/GrafttyKitTests/Teams/WorktreeAgentStateRegistryTests.swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("WorktreeAgentStateRegistry — hook-event-driven state machine")
struct WorktreeAgentStateRegistryTests {
    @Test("Unknown is the initial state.")
    func unknownInitial() {
        let r = WorktreeAgentStateRegistry()
        #expect(r.state(worktree: "/w", runtime: "codex") == .unknown)
    }

    @Test("SessionStart drives unknown → active.")
    func unknownToActive() {
        let r = WorktreeAgentStateRegistry()
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        #expect(r.state(worktree: "/w", runtime: "codex") == .active)
    }

    @Test("Stop with no recent typing drives active → idle.")
    func activeToIdleNoTyping() {
        var now = Date(timeIntervalSince1970: 1_000)
        let r = WorktreeAgentStateRegistry(now: { now })
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        r.handleStop(worktree: "/w", runtime: "codex", lastInputAt: nil)
        #expect(r.state(worktree: "/w", runtime: "codex") == .idle)

        now = Date(timeIntervalSince1970: 1_100)
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        r.handleStop(worktree: "/w", runtime: "codex", lastInputAt: Date(timeIntervalSince1970: 1_000))
        #expect(r.state(worktree: "/w", runtime: "codex") == .idle)
    }

    @Test("Stop with recent typing drives active → user_engaged.")
    func activeToUserEngaged() {
        let now = Date(timeIntervalSince1970: 1_000)
        let r = WorktreeAgentStateRegistry(now: { now })
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        r.handleStop(worktree: "/w", runtime: "codex", lastInputAt: Date(timeIntervalSince1970: 970))
        #expect(r.state(worktree: "/w", runtime: "codex") == .user_engaged)
    }

    @Test("Keystroke drives idle → user_engaged.")
    func idleToUserEngaged() {
        var now = Date(timeIntervalSince1970: 1_000)
        let r = WorktreeAgentStateRegistry(now: { now })
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        r.handleStop(worktree: "/w", runtime: "codex", lastInputAt: nil)
        now = Date(timeIntervalSince1970: 2_000)
        r.handleKeystroke(worktree: "/w", runtime: "codex")
        #expect(r.state(worktree: "/w", runtime: "codex") == .user_engaged)
    }

    @Test("PostToolUse drives idle/user_engaged → active.")
    func toolUseToActive() {
        let r = WorktreeAgentStateRegistry()
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        r.handleStop(worktree: "/w", runtime: "codex", lastInputAt: nil)
        #expect(r.state(worktree: "/w", runtime: "codex") == .idle)
        r.handlePostToolUse(worktree: "/w", runtime: "codex")
        #expect(r.state(worktree: "/w", runtime: "codex") == .active)
    }

    @Test("Engaged-grace-elapsed drives user_engaged → idle.")
    func userEngagedTimerToIdle() {
        let r = WorktreeAgentStateRegistry()
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        let now = Date()
        r.handleStop(worktree: "/w", runtime: "codex", lastInputAt: now.addingTimeInterval(-10))
        #expect(r.state(worktree: "/w", runtime: "codex") == .user_engaged)
        r.handleEngagedGraceElapsed(worktree: "/w", runtime: "codex")
        #expect(r.state(worktree: "/w", runtime: "codex") == .idle)
    }

    @Test("Engaged-grace fires while active is ignored (state stays active).")
    func userEngagedTimerWhileActiveIsNoop() {
        let r = WorktreeAgentStateRegistry()
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        r.handleEngagedGraceElapsed(worktree: "/w", runtime: "codex")
        #expect(r.state(worktree: "/w", runtime: "codex") == .active)
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

```bash
swift test --filter "WorktreeAgentStateRegistryTests"
```
Expected: compile error (`WorktreeAgentStateRegistry` doesn't exist).

- [ ] **Step 3: Implement the registry**

```swift
// Sources/GrafttyKit/Teams/WorktreeAgentStateRegistry.swift
import Foundation

/// @spec TEAM-IDLE-2.1
/// @spec TEAM-IDLE-2.2
/// In-process state machine, one record per (worktree, runtime).
/// Hook events drive active ↔ idle / user_engaged transitions; the
/// 60-second user_engaged grace is driven by the consumer scheduling
/// `handleEngagedGraceElapsed` after the last keystroke.
public final class WorktreeAgentStateRegistry: @unchecked Sendable {
    public enum AgentState: String, Sendable {
        case unknown, active, idle, user_engaged
    }

    public static let userEngagedGrace: TimeInterval = 60

    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var states: [Key: AgentState] = [:]

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func state(worktree: String, runtime: String) -> AgentState {
        lock.lock(); defer { lock.unlock() }
        return states[Key(worktree, runtime)] ?? .unknown
    }

    public func handleSessionStart(worktree: String, runtime: String) {
        set(.active, worktree: worktree, runtime: runtime)
    }

    public func handlePostToolUse(worktree: String, runtime: String) {
        set(.active, worktree: worktree, runtime: runtime)
    }

    public func handleStop(worktree: String, runtime: String, lastInputAt: Date?) {
        let recentlyTyping: Bool = {
            guard let lastInputAt else { return false }
            return now().timeIntervalSince(lastInputAt) < Self.userEngagedGrace
        }()
        set(recentlyTyping ? .user_engaged : .idle, worktree: worktree, runtime: runtime)
    }

    public func handleKeystroke(worktree: String, runtime: String) {
        lock.lock(); defer { lock.unlock() }
        let key = Key(worktree, runtime)
        if states[key] == .idle { states[key] = .user_engaged }
    }

    public func handleEngagedGraceElapsed(worktree: String, runtime: String) {
        lock.lock(); defer { lock.unlock() }
        let key = Key(worktree, runtime)
        if states[key] == .user_engaged { states[key] = .idle }
    }

    private func set(_ state: AgentState, worktree: String, runtime: String) {
        lock.lock(); defer { lock.unlock() }
        states[Key(worktree, runtime)] = state
    }

    private struct Key: Hashable {
        let worktree: String
        let runtime: String
        init(_ w: String, _ r: String) { self.worktree = w; self.runtime = r }
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

```bash
swift test --filter "WorktreeAgentStateRegistryTests"
```
Expected: 7/7 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Teams/WorktreeAgentStateRegistry.swift Tests/GrafttyKitTests/Teams/WorktreeAgentStateRegistryTests.swift
git commit -m "feat(teams): add WorktreeAgentStateRegistry state machine

Per-(worktree, runtime) state machine driven by hook events.
unknown → active on SessionStart; active ↔ idle/user_engaged on
Stop with the typing-recency check; PostToolUse returns to active;
keystrokes flip idle → user_engaged; the 60s grace is consumer-
scheduled via handleEngagedGraceElapsed.

@spec TEAM-IDLE-2.1
@spec TEAM-IDLE-2.2"
```

---

## Task 3: `PaneInputActivityRegistry` — `[PaneID: Date]` clock-injectable store

**Files:**
- Create: `Sources/GrafttyKit/Teams/PaneInputActivityRegistry.swift`
- Create: `Tests/GrafttyKitTests/Teams/PaneInputActivityRegistryTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/GrafttyKitTests/Teams/PaneInputActivityRegistryTests.swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("PaneInputActivityRegistry — per-pane last-keystroke timestamp")
struct PaneInputActivityRegistryTests {
    @Test("Initial lookup is nil.")
    func initialNil() {
        let r = PaneInputActivityRegistry()
        #expect(r.lastInputAt(paneID: UUID()) == nil)
    }

    @Test("Recording returns the recorded timestamp.")
    func recordThenRead() {
        let pane = UUID()
        var now = Date(timeIntervalSince1970: 1_000)
        let r = PaneInputActivityRegistry(now: { now })
        r.recordKeystroke(paneID: pane)
        #expect(r.lastInputAt(paneID: pane) == now)
        now = Date(timeIntervalSince1970: 1_100)
        r.recordKeystroke(paneID: pane)
        #expect(r.lastInputAt(paneID: pane) == now)
    }

    @Test("Distinct panes are independent.")
    func independentPanes() {
        var now = Date(timeIntervalSince1970: 1_000)
        let r = PaneInputActivityRegistry(now: { now })
        let a = UUID()
        let b = UUID()
        r.recordKeystroke(paneID: a)
        now = Date(timeIntervalSince1970: 1_010)
        r.recordKeystroke(paneID: b)
        #expect(r.lastInputAt(paneID: a) == Date(timeIntervalSince1970: 1_000))
        #expect(r.lastInputAt(paneID: b) == Date(timeIntervalSince1970: 1_010))
    }
}
```

- [ ] **Step 2: Run, expect failure**

```bash
swift test --filter "PaneInputActivityRegistryTests"
```

- [ ] **Step 3: Implement**

```swift
// Sources/GrafttyKit/Teams/PaneInputActivityRegistry.swift
import Foundation

/// @spec TEAM-IDLE-2.2
/// Process-wide per-pane "last user keystroke landed at" map. Written
/// by `PaneInputActivityObserver` at the libghostty input boundary,
/// read by `IdleDeliveryService` for the 60s user-engaged gate.
public final class PaneInputActivityRegistry: @unchecked Sendable {
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var stamps: [UUID: Date] = [:]

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func recordKeystroke(paneID: UUID) {
        lock.lock(); defer { lock.unlock() }
        stamps[paneID] = now()
    }

    public func lastInputAt(paneID: UUID) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return stamps[paneID]
    }
}
```

- [ ] **Step 4: Run, expect pass**

```bash
swift test --filter "PaneInputActivityRegistryTests"
```

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Teams/PaneInputActivityRegistry.swift Tests/GrafttyKitTests/Teams/PaneInputActivityRegistryTests.swift
git commit -m "feat(teams): add PaneInputActivityRegistry

Process-wide [PaneID: Date] map of last-keystroke timestamps,
written by the libghostty-input observer (next task) and read by
IdleDeliveryService for the 60s user-engaged gate.

@spec TEAM-IDLE-2.2"
```

---

## Task 4: Add new event kinds to `TeamEventLog`

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamEventLog.swift`
- Modify: `Tests/GrafttyKitTests/Teams/TeamEventLogTests.swift` (if exists; else create)

- [ ] **Step 1: Inspect existing event kinds**

```bash
grep -n "TeamEventKind\|case .agent\|case .nudge\|enum TeamEventKind\|TeamEvent(" Sources/GrafttyKit/Teams/TeamEventLog.swift
```

- [ ] **Step 2: Write failing test**

Add to (or create) `Tests/GrafttyKitTests/Teams/TeamEventLogTests.swift`:

```swift
@Test("agentStateTransition and zmxNudgeAttempt encode to JSON with stable shape.")
func newEventKindsEncode() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("graftty-eventlog-\(UUID().uuidString)")
    let log = TeamEventLog(rootDirectory: dir)
    try log.append(TeamEvent(
        teamID: "/r",
        timestamp: Date(timeIntervalSince1970: 1),
        kind: .agentStateTransition,
        detail: ["from": "active", "to": "idle", "runtime": "codex", "worktree": "/r/alice", "trigger": "stop"]
    ))
    try log.append(TeamEvent(
        teamID: "/r",
        timestamp: Date(timeIntervalSince1970: 2),
        kind: .zmxNudgeAttempt,
        detail: ["worktree": "/r/alice", "runtime": "codex", "outcome": "sent", "messageIDs": "id-1,id-2"]
    ))
    let url = dir.appendingPathComponent(TeamInbox.fileComponent("/r"), isDirectory: true)
        .appendingPathComponent("events.jsonl")
    let text = try String(contentsOf: url)
    #expect(text.contains("\"kind\":\"agentStateTransition\""))
    #expect(text.contains("\"kind\":\"zmxNudgeAttempt\""))
}
```

- [ ] **Step 3: Run, expect failure**

```bash
swift test --filter "TeamEventLogTests/newEventKindsEncode"
```
Expected: `.agentStateTransition` / `.zmxNudgeAttempt` undefined.

- [ ] **Step 4: Add the new cases to `TeamEventKind`**

In `TeamEventLog.swift`, find the `TeamEventKind` enum and add:

```swift
case agentStateTransition
case zmxNudgeAttempt
```

- [ ] **Step 5: Run, expect pass**

```bash
swift test --filter "TeamEventLogTests"
```

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamEventLog.swift Tests/GrafttyKitTests/Teams/TeamEventLogTests.swift
git commit -m "feat(teams): add agentStateTransition and zmxNudgeAttempt event kinds

Two new TeamEventKind cases for observability of the new
event-driven idle delivery path. Pipeline unchanged: events.jsonl
is appended via POSIX O_APPEND and never routed through
TeamEventDispatcher, so observability cannot loop back as inbox
messages.

@spec TEAM-IDLE-2.7"
```

---

## Task 5: Rewrite `IdleDeliveryService` as event-driven

**Files:**
- Modify: `Sources/GrafttyKit/Teams/IdleDeliveryService.swift`
- Modify: `Tests/GrafttyTests/Specs/IdleDeliveryTests.swift` (existing TEAM-IDLE-2.x tests)

- [ ] **Step 1: Write the new contract tests**

Replace the contents of `Tests/GrafttyTests/Specs/IdleDeliveryTests.swift` with:

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("IdleDeliveryService — event-driven idle delivery")
struct IdleDeliveryServiceTests {
    @Test("@spec TEAM-IDLE-2.1: While the worktree state is idle, onStop with pending messages calls the nudge sender and advances the watermark.")
    func onStopIdleWithPendingDelivers() async throws {
        let f = try Fixture()
        try f.appendUnread(id: "m-1", body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)

        await f.service.onStop(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: f.paneID)

        #expect(f.sender.calls.count == 1)
        #expect(f.sender.calls[0].messageIDs == ["m-1"])
        #expect(try f.inbox.zmxWatermark(teamID: f.teamID, worktree: f.worktree, runtime: "codex") == "m-1")
    }

    @Test("@spec TEAM-IDLE-2.2: While the worktree state is user_engaged, onStop defers — no nudge, no watermark advance.")
    func onStopUserEngagedDefers() async throws {
        let f = try Fixture()
        try f.appendUnread(id: "m-1", body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: f.now())

        await f.service.onStop(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: f.paneID)

        #expect(f.sender.calls.isEmpty)
        #expect(try f.inbox.zmxWatermark(teamID: f.teamID, worktree: f.worktree, runtime: "codex") == nil)
    }

    @Test("@spec TEAM-IDLE-2.3: A second onStop with same state and watermark does not redeliver.")
    func dedupedOnStop() async throws {
        let f = try Fixture()
        try f.appendUnread(id: "m-1", body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)
        await f.service.onStop(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: f.paneID)
        await f.service.onStop(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: f.paneID)
        #expect(f.sender.calls.count == 1)
    }

    @Test("@spec TEAM-IDLE-2.4: With no pane (paneID nil), onStop logs skip-no-pane and does not call the sender.")
    func noPaneSkipsAndLogs() async throws {
        let f = try Fixture()
        try f.appendUnread(id: "m-1", body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)
        await f.service.onStop(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: nil)
        #expect(f.sender.calls.isEmpty)
    }

    @Test("@spec TEAM-IDLE-2.1: onMessageArrival with idle delivers; with active is a no-op.")
    func onMessageArrivalGatedByState() async throws {
        let f = try Fixture()
        try f.appendUnread(id: "m-1", body: "hello")

        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: f.paneID)
        #expect(f.sender.calls.isEmpty, "active state must not deliver")

        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)
        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: f.paneID)
        #expect(f.sender.calls.count == 1)
    }

    final class StubSender: NudgeSender, @unchecked Sendable {
        struct Call { let paneID: UUID; let text: String; let messageIDs: [String] }
        var calls: [Call] = []
        func send(paneID: UUID, message: String, messageIDs: [String]) async {
            calls.append(.init(paneID: paneID, text: message, messageIDs: messageIDs))
        }
    }

    struct Fixture {
        let teamID = "/repo"
        let worktree = "/repo/.worktrees/alice"
        let paneID = UUID()
        let sender = StubSender()
        let state = WorktreeAgentStateRegistry()
        let inbox: TeamInbox
        let service: IdleDeliveryService
        let now: () -> Date

        init() throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-idle-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let frozen = Date(timeIntervalSince1970: 1_700_000_000)
            self.now = { frozen }
            self.inbox = TeamInbox(rootDirectory: dir, idGenerator: { UUID().uuidString }, now: { frozen })
            self.service = IdleDeliveryService(
                inbox: inbox,
                state: state,
                nudgeSender: sender,
                eventLog: nil,
                now: { frozen }
            )
        }

        func appendUnread(id: String, body: String) throws {
            _ = try inbox.appendMessage(
                teamID: teamID,
                teamName: "repo",
                repoPath: "/repo",
                from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
                to: TeamInboxEndpoint(member: "alice", worktree: worktree, runtime: nil),
                priority: .normal,
                kind: "team_message",
                body: body,
                idOverride: id
            )
        }
    }
}
```

(This contract assumes a new convenience `idOverride` parameter on `appendMessage` for tests; if not present, use the existing `idGenerator` injection to control IDs.)

- [ ] **Step 2: Run, expect compilation failures**

The new `IdleDeliveryService` API (`init(inbox:state:nudgeSender:eventLog:now:)`, `onStop(...)`, `onMessageArrival(...)`) doesn't exist yet.

- [ ] **Step 3: Rewrite `IdleDeliveryService`**

Replace the polling-based actor with an event-driven actor. Drop `presence`, `inputState`, `sessionLookup`, `lastNudgedHead`/`lastSkipReason` (replaced by zmxWatermark + state machine). Keep the `NudgeSender` protocol unchanged.

```swift
import Foundation

public protocol NudgeSender: Sendable {
    func send(paneID: UUID, message: String, messageIDs: [String]) async
}

/// @spec TEAM-IDLE-2.1
/// @spec TEAM-IDLE-2.3
/// @spec TEAM-IDLE-2.4
/// @spec TEAM-IDLE-2.5
/// @spec TEAM-IDLE-2.6
/// Event-driven Codex idle-delivery dispatcher. Receives Stop and
/// new-message-arrival signals, queries the agent-state registry,
/// and on `idle` sends pending messages via NudgeSender then
/// advances the per-(team,worktree,runtime) zmxWatermark.
public actor IdleDeliveryService {
    private let inbox: TeamInbox
    private let state: WorktreeAgentStateRegistry
    private let nudgeSender: NudgeSender
    private let eventLog: TeamEventLog?
    private let now: @Sendable () -> Date

    public init(
        inbox: TeamInbox,
        state: WorktreeAgentStateRegistry,
        nudgeSender: NudgeSender,
        eventLog: TeamEventLog? = TeamEventLog.defaultLog(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inbox = inbox
        self.state = state
        self.nudgeSender = nudgeSender
        self.eventLog = eventLog
        self.now = now
    }

    public func onStop(team: String, worktree: String, runtime: String, paneID: UUID?) async {
        await maybeDeliver(team: team, worktree: worktree, runtime: runtime, paneID: paneID, trigger: "stop")
    }

    public func onMessageArrival(team: String, worktree: String, runtime: String, paneID: UUID?) async {
        await maybeDeliver(team: team, worktree: worktree, runtime: runtime, paneID: paneID, trigger: "messageArrival")
    }

    private func maybeDeliver(team: String, worktree: String, runtime: String, paneID: UUID?, trigger: String) async {
        let s = state.state(worktree: worktree, runtime: runtime)
        guard s == .idle else {
            log(team: team, worktree: worktree, runtime: runtime,
                outcome: "skipped_state_\(s.rawValue)")
            return
        }
        guard let paneID else {
            log(team: team, worktree: worktree, runtime: runtime, outcome: "skipped_no_pane")
            return
        }
        let watermark: String?
        do { watermark = try inbox.zmxWatermark(teamID: team, worktree: worktree, runtime: runtime) }
        catch { log(team: team, worktree: worktree, runtime: runtime, outcome: "error_watermark_read"); return }

        let pending: [TeamInboxMessage]
        do {
            pending = try inbox.unreadMessages(teamID: team, recipientWorktree: worktree, after: watermark)
        } catch {
            log(team: team, worktree: worktree, runtime: runtime, outcome: "error_inbox_read"); return
        }
        guard !pending.isEmpty else {
            log(team: team, worktree: worktree, runtime: runtime, outcome: "skipped_no_pending"); return
        }

        let text = TeamHookRenderer.format(messages: pending) + "\r"
        await nudgeSender.send(paneID: paneID, message: text, messageIDs: pending.map(\.id))
        do {
            try inbox.advanceZmxWatermark(teamID: team, worktree: worktree, runtime: runtime, to: pending.last!.id)
        } catch {
            log(team: team, worktree: worktree, runtime: runtime, outcome: "error_watermark_write"); return
        }
        log(team: team, worktree: worktree, runtime: runtime,
            outcome: "sent", messageIDs: pending.map(\.id), trigger: trigger)
    }

    private func log(
        team: String, worktree: String, runtime: String,
        outcome: String, messageIDs: [String] = [], trigger: String = ""
    ) {
        guard let eventLog else { return }
        var detail: [String: String] = ["worktree": worktree, "runtime": runtime, "outcome": outcome]
        if !messageIDs.isEmpty { detail["messageIDs"] = messageIDs.joined(separator: ",") }
        if !trigger.isEmpty { detail["trigger"] = trigger }
        try? eventLog.append(TeamEvent(teamID: team, timestamp: now(), kind: .zmxNudgeAttempt, detail: detail))
    }
}
```

(If `TeamPresenceRecord`'s init signature differs, adapt — the goal is to pass the recipient through to `NudgeSender` so the existing protocol shape works.)

- [ ] **Step 4: Run, expect pass**

```bash
swift test --filter "IdleDeliveryServiceTests"
```

- [ ] **Step 5: Delete obsolete test fixtures**

The replaced tests previously covered the polling/staleness/typing-gate path. Confirm none of the deleted helpers are referenced elsewhere:
```bash
grep -rn "lastNudgedHead\|lastSkipReason\|startPolling\|sessionLookup\|inputState" Tests/ Sources/GrafttyKit/ | head
```
Remove anything dead.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Teams/IdleDeliveryService.swift Tests/GrafttyTests/Specs/IdleDeliveryTests.swift
git commit -m "refactor(teams): rewrite IdleDeliveryService as event-driven

Replaces 10s polling + 60s staleness threshold + uncommitted-byte
typing gate with two entry points: onStop (called from the Stop
hook side-effect) and onMessageArrival (subscribed to
TeamInboxObserver). Both consult the WorktreeAgentStateRegistry —
delivery happens iff state == idle.

@spec TEAM-IDLE-2.1
@spec TEAM-IDLE-2.3
@spec TEAM-IDLE-2.5"
```

---

## Task 6: `ZmxNudgeSender` — real in-process zmx send

**Files:**
- Modify: `Sources/GrafttyKit/Teams/IdleDeliveryService.swift` (the `ZmxNudgeSender` class at the bottom)
- Create: `Tests/GrafttyKitTests/Teams/ZmxNudgeSenderTests.swift`

- [ ] **Step 1: Inspect the in-process zmx send API**

```bash
grep -rn "func send\|writeToPTY\|sendKeystrokes\|class ZmxLauncher\|public func sessionName" Sources/GrafttyKit/Zmx/ | head
```

The pane's session name is `ZmxLauncher.sessionName(for: paneID)`. Find the in-process write API used by the existing `zmx send` CLI subcommand.

- [ ] **Step 2: Write integration-style test with stubbed zmx writer**

```swift
// Tests/GrafttyKitTests/Teams/ZmxNudgeSenderTests.swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("ZmxNudgeSender — pane-targeted in-process zmx-send")
struct ZmxNudgeSenderTests {
    @Test("send invokes the writer with the resolved session name and payload.")
    func writesToResolvedSession() async {
        let stubWriter = StubZmxWriter()
        let sender = ZmxNudgeSender(writer: stubWriter)
        let paneID = UUID()
        await sender.send(paneID: paneID, message: "hello", messageIDs: ["m-1"])
        #expect(stubWriter.writes.count == 1)
        #expect(stubWriter.writes[0].sessionName == ZmxLauncher.sessionName(for: paneID))
        #expect(stubWriter.writes[0].text == "hello")
    }

    final class StubZmxWriter: ZmxWriter, @unchecked Sendable {
        struct Call { let sessionName: String; let text: String }
        var writes: [Call] = []
        func write(sessionName: String, text: String) async throws {
            writes.append(.init(sessionName: sessionName, text: text))
        }
    }
}
```

- [ ] **Step 3: Run, expect failure**

```bash
swift test --filter "ZmxNudgeSenderTests"
```

- [ ] **Step 4: Implement `ZmxWriter` protocol and update `ZmxNudgeSender`**

Add `ZmxWriter` protocol (in `Zmx` directory if that's idiomatic, else inline):

```swift
public protocol ZmxWriter: Sendable {
    func write(sessionName: String, text: String) async throws
}
```

Replace the `ZmxNudgeSender` class:

```swift
/// @spec TEAM-IDLE-2.6
public final class ZmxNudgeSender: NudgeSender {
    private let writer: ZmxWriter
    public init(writer: ZmxWriter) {
        self.writer = writer
    }
    public func send(paneID: UUID, message: String, messageIDs: [String]) async {
        let session = ZmxLauncher.sessionName(for: paneID)
        do { try await writer.write(sessionName: session, text: message) }
        catch { NSLog("[Graftty] zmx send failed for %@: %@", session, "\(error)") }
    }
}
```

Wire a production `ZmxWriter` adapter (in app boot wiring — Task 9) that calls into the in-process API found in Step 1.

- [ ] **Step 5: Run, expect pass**

```bash
swift test --filter "ZmxNudgeSenderTests"
```

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Teams/IdleDeliveryService.swift Tests/GrafttyKitTests/Teams/ZmxNudgeSenderTests.swift
git commit -m "feat(teams): wire ZmxNudgeSender through ZmxWriter protocol

Replaces NSLog stub with a protocol seam. Tests inject a stub
writer; production wires the in-process zmx PTY-write path used
by the existing 'zmx send' CLI surface. paneID nil short-circuits.

@spec TEAM-IDLE-2.6"
```

---

## Task 7: Stop-hook side-effect into `IdleDeliveryService`

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift`
- Modify: `Tests/GrafttyKitTests/Teams/TeamInboxRequestHandlerTests.swift`

- [ ] **Step 1: Write failing test asserting onStop is invoked**

Add to `TeamInboxRequestHandlerTests.swift`:

```swift
@Test("@spec TEAM-IDLE-2.5: Stop hook fires IdleDeliveryService.onStop as a side-effect; renderer return value stays {}.")
func stopHookFiresIdleDelivery() throws {
    let root = try Self.temporaryDirectory()
    let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
    let inbox = TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
    let recorder = OnStopRecorder()
    let handler = Self.makeHandler(inbox: inbox, idleService: recorder.asService())

    _ = try handler.send(
        callerWorktree: "/repo", recipient: "alice", text: "hi",
        priority: .normal, repos: [repo], teamsEnabled: true
    )
    let stopOutput = try handler.hook(
        callerWorktree: "/repo/.worktrees/alice", runtime: .codex,
        event: .stop, sessionID: "s-1", repos: [repo], teamsEnabled: true
    )

    #expect(stopOutput == "{}")
    #expect(recorder.calls.count == 1)
    #expect(recorder.calls[0].worktree == "/repo/.worktrees/alice")
}

// In the same file:
final class OnStopRecorder: @unchecked Sendable {
    struct Call { let team: String; let worktree: String; let runtime: String }
    var calls: [Call] = []
    func record(_ team: String, _ worktree: String, _ runtime: String) {
        calls.append(.init(team: team, worktree: worktree, runtime: runtime))
    }
    // Adapt to whatever shape the handler expects (closure or service).
    // The plan assumes the handler accepts an optional closure
    // `onStop: ((team, worktree, runtime, paneID?) -> Void)?`.
    func asService() -> ((String, String, String, UUID?) -> Void) {
        { [self] t, w, r, _ in record(t, w, r) }
    }
}
```

- [ ] **Step 2: Run, expect failure**

```bash
swift test --filter "TeamInboxRequestHandlerTests/stopHookFiresIdleDelivery"
```

- [ ] **Step 3: Plumb `onStop` callback through the handler**

In `TeamInboxRequestHandler`'s init, accept an optional closure:

```swift
private let onStop: (@Sendable (String, String, String, UUID?) -> Void)?

public init(
    inbox: TeamInbox,
    sessionPromptRenderer: ((TeamView, TeamMember) -> String?)? = nil,
    onStop: (@Sendable (String, String, String, UUID?) -> Void)? = nil
) {
    self.inbox = inbox
    self.sessionPromptRenderer = sessionPromptRenderer
    self.onStop = onStop
}
```

In `case .stop:`, fire the callback before returning:

```swift
case .stop:
    onStop?(teamID, context.sender.worktreePath, runtime.rawValue, nil)
    return try TeamHookRenderer.stop(runtime: runtime, messages: [])
```

(`paneID: nil` here — the handler doesn't know about panes. Wiring in Task 9 resolves the pane and re-dispatches via the actor at app boot.)

Update `Self.makeHandler` test helper to accept `idleService:` parameter and forward it as `onStop:`.

Production app wiring will pass a closure that calls `Task { await idleService.onStop(team:..., paneID: panes(for: worktree).first?.paneID) }`.

- [ ] **Step 4: Run, expect pass**

```bash
swift test --filter "TeamInboxRequestHandlerTests"
```

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift Tests/GrafttyKitTests/Teams/TeamInboxRequestHandlerTests.swift
git commit -m "feat(teams): Stop hook fires IdleDeliveryService.onStop side-effect

Adds an optional onStop callback to TeamInboxRequestHandler. The
.stop case invokes it before returning {}. Test asserts the
callback fires and the renderer return value is unchanged.

@spec TEAM-IDLE-2.5"
```

---

## Task 8: `PaneInputActivityObserver` — libghostty input boundary tap

**Files:**
- Create: `Sources/Graftty/Surface/PaneInputActivityObserver.swift` (or wherever the libghostty SwiftUI surface lives)
- Tests: covered indirectly via Task 11 integration test (the observer is glue between SwiftUI and the registry)

- [ ] **Step 1: Locate the SwiftUI input boundary**

```bash
grep -rn "performKey\|insertText\|interpretKeyEvents\|class TerminalView\|libghostty\|ghosttyKit\|onKey" Sources/Graftty/ | head -15
```

Identify the single point where every PTY-bound keystroke flows. Likely a NSView/NSResponder method or a SwiftUI `onKeyPress` modifier on the surface.

- [ ] **Step 2: Implement the observer**

```swift
// Sources/Graftty/Surface/PaneInputActivityObserver.swift
import SwiftUI
import GrafttyKit

/// @spec TEAM-IDLE-2.2
/// Records "the user just typed" timestamps into PaneInputActivityRegistry.
/// Wired at the libghostty input boundary so it sees every keystroke
/// regardless of whether the source was the WebSession or a native key
/// event. Read by IdleDeliveryService for the 60s user-engaged gate.
@MainActor
final class PaneInputActivityObserver {
    private let registry: PaneInputActivityRegistry
    init(registry: PaneInputActivityRegistry) { self.registry = registry }

    func recordKeystroke(paneID: UUID) {
        registry.recordKeystroke(paneID: paneID)
    }
}
```

Tap the input point. If a SwiftUI modifier:

```swift
.onKeyPress { _ in
    inputActivityObserver.recordKeystroke(paneID: paneID)
    return .ignored  // don't consume — passthrough
}
```

If an NSResponder method override (preferred since libghostty is AppKit-based), patch the existing override to call the observer first, then super:

```swift
override func keyDown(with event: NSEvent) {
    inputActivityObserver?.recordKeystroke(paneID: paneID)
    super.keyDown(with: event)
}
```

The observer must be passive — never consume events, never throw, never block.

- [ ] **Step 3: Manual smoke test (deferred to Task 11)**

Full integration verification deferred to the end-to-end test in Task 11. This task only ensures:
- The observer compiles cleanly.
- It's plumbed through `GrafttyApp` startup so `inputActivityObserver` is non-nil at the surface.

```bash
swift build
```
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add Sources/Graftty/
git commit -m "feat(graftty): tap libghostty input for keystroke timestamps

PaneInputActivityObserver records last-keystroke timestamps into
PaneInputActivityRegistry at the input boundary. Used by
IdleDeliveryService to gate zmx-send on 60s of no user typing.

@spec TEAM-IDLE-2.2"
```

---

## Task 9: App-level wiring + 60s engaged-grace timer

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift` (existing IdleDeliveryService boot path)
- Create or modify: a small `EngagedGraceScheduler` helper if it doesn't fit inline

- [ ] **Step 1: Replace existing IdleDeliveryService instantiation**

In `GrafttyApp.startup()`, find the current `IdleDeliveryService(...)` and `Task { await service.startPolling() }` block. Replace with:

```swift
let stateRegistry = WorktreeAgentStateRegistry()
let inputRegistry = PaneInputActivityRegistry()
let zmxWriter = AppZmxWriter()  // adapter calling the in-process zmx PTY write
let idleService = IdleDeliveryService(
    inbox: teamInbox,
    state: stateRegistry,
    nudgeSender: ZmxNudgeSender(writer: zmxWriter)
)

// Subscribe to inbox arrivals.
teamInboxObserver.onMessage = { [weak idleService, stateRegistry, weak self] message in
    guard let self, let idleService else { return }
    let runtime = message.to.runtime ?? "codex"
    let paneID = self.firstPaneID(for: message.to.worktree)
    Task { await idleService.onMessageArrival(
        team: message.teamID, worktree: message.to.worktree, runtime: runtime, paneID: paneID
    ) }
}

// Plumb hook handler.
let handler = TeamInboxRequestHandler(
    inbox: teamInbox,
    sessionPromptRenderer: { ... },
    onStop: { [weak idleService, weak self] team, worktree, runtime, _ in
        guard let idleService, let self else { return }
        let paneID = self.firstPaneID(for: worktree)
        Task { await idleService.onStop(team: team, worktree: worktree, runtime: runtime, paneID: paneID) }
    }
)
```

Add the `firstPaneID(for:)` helper that pulls from graftty's existing pane-per-worktree map.

- [ ] **Step 2: Wire SessionStart / PostToolUse → state registry**

In `TeamInboxRequestHandler` init (or via similar callbacks), plumb `onSessionStart` and `onPostToolUse` callbacks the same way as `onStop`. The hook handler invokes the callback as a side-effect; the app wires it to `stateRegistry.handleSessionStart(...)` / `handlePostToolUse(...)`.

- [ ] **Step 3: Wire keystroke observer → state registry**

The `PaneInputActivityObserver.recordKeystroke` already writes to `PaneInputActivityRegistry`. Add a side-effect call to `stateRegistry.handleKeystroke(worktree:runtime:)`:

```swift
func recordKeystroke(paneID: UUID) {
    registry.recordKeystroke(paneID: paneID)
    if let mapping = paneToWorktreeRuntime(paneID) {
        stateRegistry.handleKeystroke(worktree: mapping.worktree, runtime: mapping.runtime)
        graceScheduler.bump(worktree: mapping.worktree, runtime: mapping.runtime)
    }
}
```

- [ ] **Step 4: Implement `EngagedGraceScheduler`**

Per-worktree `Timer` rescheduled on each keystroke; on fire, calls `stateRegistry.handleEngagedGraceElapsed(...)` then `idleService.onMessageArrival(...)` to give pending messages a chance to deliver.

```swift
@MainActor
final class EngagedGraceScheduler {
    private var timers: [Key: Timer] = [:]
    private let state: WorktreeAgentStateRegistry
    private let onElapsed: (String, String) -> Void

    init(state: WorktreeAgentStateRegistry, onElapsed: @escaping (String, String) -> Void) {
        self.state = state
        self.onElapsed = onElapsed
    }

    func bump(worktree: String, runtime: String) {
        let key = Key(worktree, runtime)
        timers[key]?.invalidate()
        timers[key] = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.state.handleEngagedGraceElapsed(worktree: worktree, runtime: runtime)
                self.onElapsed(worktree, runtime)
            }
        }
    }

    private struct Key: Hashable { let worktree: String; let runtime: String
        init(_ w: String, _ r: String) { self.worktree = w; self.runtime = r } }
}
```

- [ ] **Step 5: Build, smoke test**

```bash
swift build
```

Manual smoke test:
1. Open graftty, open two worktrees, run codex in worktree A.
2. From worktree B's shell, `graftty team msg <A> "hello there"`.
3. Confirm "hello there" appears in worktree A's pane and Codex picks it up.
4. Repeat with active typing in A — confirm delivery is deferred 60s.

- [ ] **Step 6: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift Sources/Graftty/Surface/
git commit -m "feat(graftty): wire event-driven Codex idle delivery

Replaces the polling startup with hook-event-driven dispatch.
GrafttyApp builds the state registry, input registry, and idle
service, plumbs onStop / onSessionStart / onPostToolUse callbacks
through TeamInboxRequestHandler, subscribes the service to inbox
arrivals, and schedules per-worktree 60s engaged-grace timers
that fire on the last keystroke.

@spec TEAM-IDLE-2.1
@spec TEAM-IDLE-2.4
@spec TEAM-IDLE-2.5"
```

---

## Task 10: `@spec` annotation updates

**Files:**
- Modify: existing `@spec TEAM-IDLE-2.1` / `TEAM-IDLE-2.2` annotations in test titles
- Modify: existing `@spec` doc comments on types
- Add: `@spec TEAM-IDLE-2.4` / `2.5` / `2.6` / `2.7` annotations on the new types
- Possibly delete: `*Todo.swift` entries for any spec ID we just promoted to a real test

- [ ] **Step 1: Update TEAM-IDLE-2.1 EARS text**

In `Tests/GrafttyTests/Specs/IdleDeliveryTests.swift` (already updated in Task 5), confirm the `@Test` title:

```
@spec TEAM-IDLE-2.1: While the worktree state is idle, onStop with pending messages calls the nudge sender and advances the watermark.
```

In `Sources/Graftty/GrafttyApp.swift` and any `@spec TEAM-IDLE-2.1` doc-comment, update text to match.

```bash
grep -rn "@spec TEAM-IDLE-2.1" Sources/ Tests/
```

- [ ] **Step 2: Update TEAM-IDLE-2.2 EARS text**

Replace `"While the user has uncommitted typed bytes for a Codex agent's pane, the application shall not deliver a nudge to that agent."` with the new wording from the spec.

```bash
grep -rn "@spec TEAM-IDLE-2.2" Sources/ Tests/
```

Update `Sources/GrafttyKit/Zmx/ZmxInputState.swift`'s `@spec TEAM-IDLE-2.2` doc comment — either remove (if the type no longer hosts that spec) or update text. Likely **remove**: `ZmxInputState` is no longer the typing-gate authority. Replace with a smaller doc comment that doesn't claim a spec.

- [ ] **Step 3: Add TEAM-IDLE-2.4/2.5/2.6/2.7 to new types**

These were sketched into the source code in earlier tasks via doc-comment `@spec` markers. Confirm with grep:

```bash
grep -rn "@spec TEAM-IDLE-2\.\(4\|5\|6\|7\)" Sources/
```

Add `@Test` entries in `Tests/GrafttyKitTests/Teams/` (or `Tests/GrafttyTests/Specs/`) so each spec ID has a behavioral test:

- 2.4 — first-pane targeting + skip-no-pane (already in `IdleDeliveryServiceTests`)
- 2.5 — Stop hook side-effect (already in Task 7)
- 2.6 — zmx-watermark + auto-submit format (split: watermark in Task 1, format in `ZmxNudgeSenderTests`)
- 2.7 — observability rows in `events.jsonl` (Task 4)

- [ ] **Step 4: Promote any disabled `*Todo.swift` entries**

```bash
grep -n "TEAM-IDLE" Tests/GrafttyTests/Specs/IdleDeliveryTodo.swift 2>/dev/null
```

Delete promoted entries. If `IdleDeliveryTodo.swift` no longer has any `@Test`, leave the file with the existing `import` but no entries (or delete it; CI doesn't care).

- [ ] **Step 5: Run scripts/generate-specs.py to verify**

```bash
scripts/generate-specs.py
```

If it reports duplicate IDs (test + Todo), fix by deleting the Todo.

- [ ] **Step 6: Commit**

```bash
git add Sources/ Tests/ SPECS.md
git commit -m "docs(specs): update TEAM-IDLE @spec text + add 2.4-2.7

Retitles 2.1 (event-driven) and 2.2 (60s-since-keystroke); adds
new 2.4 (first-pane targeting), 2.5 (Stop side-effect), 2.6
(zmx-watermark + auto-submit), 2.7 (observability via events.jsonl).
Regenerates SPECS.md."
```

---

## Task 11: End-to-end integration test

**Files:**
- Create: `Tests/GrafttyKitTests/Teams/IdleDeliveryEndToEndTests.swift`

- [ ] **Step 1: Write the test**

```swift
// Tests/GrafttyKitTests/Teams/IdleDeliveryEndToEndTests.swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("Idle delivery end-to-end — Stop hook → state → zmx-send")
struct IdleDeliveryEndToEndTests {
    @Test("Stop hook + idle state + pending message → zmx writer receives formatted text + \\r.")
    func stopFiresZmxSend() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let inbox = TeamInbox(rootDirectory: dir, idGenerator: { UUID().uuidString }, now: { Date() })
        let state = WorktreeAgentStateRegistry()
        let writer = StubWriter()
        let service = IdleDeliveryService(
            inbox: inbox, state: state, nudgeSender: ZmxNudgeSender(writer: writer)
        )
        let pane = UUID()
        let worktree = "/repo/.worktrees/alice"
        let team = "/repo"

        _ = try inbox.appendMessage(
            teamID: team, teamName: "repo", repoPath: "/repo",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
            to: TeamInboxEndpoint(member: "alice", worktree: worktree, runtime: nil),
            priority: .normal, kind: "team_message", body: "hello"
        )

        state.handleSessionStart(worktree: worktree, runtime: "codex")
        state.handleStop(worktree: worktree, runtime: "codex", lastInputAt: nil)
        await service.onStop(team: team, worktree: worktree, runtime: "codex", paneID: pane)

        #expect(writer.writes.count == 1)
        #expect(writer.writes[0].text.hasSuffix("\r"))
        #expect(writer.writes[0].sessionName == ZmxLauncher.sessionName(for: pane))
    }

    final class StubWriter: ZmxWriter, @unchecked Sendable {
        struct W { let sessionName: String; let text: String }
        var writes: [W] = []
        func write(sessionName: String, text: String) async throws {
            writes.append(.init(sessionName: sessionName, text: text))
        }
    }
}
```

- [ ] **Step 2: Run, expect pass**

```bash
swift test --filter "IdleDeliveryEndToEndTests"
```

- [ ] **Step 3: Run full suite to confirm no regressions**

```bash
swift test
```
Expected: 1419+ tests pass (count goes up by however many we added).

- [ ] **Step 4: Run /simplify on the diff**

Per `CLAUDE.md`, run `/simplify` on the changed files before opening the PR. Apply any improvements it surfaces.

- [ ] **Step 5: Commit**

```bash
git add Tests/GrafttyKitTests/Teams/IdleDeliveryEndToEndTests.swift
git commit -m "test(teams): end-to-end Stop → idle → zmx-send

Integration test wiring the full pipeline: append message, fire
SessionStart + Stop, invoke onStop, assert ZmxWriter received the
formatted text + carriage return at the resolved session name."
```
