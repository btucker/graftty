# Claude Session Registry + Pane-Level Status — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Poll `claude agents --json` to derive per-pane busy/idle liveness, surface it as pane-scoped status pills (notify-wins), and re-home agent "needs input" + a new `graftty notify --session/--worktree` grammar to the pane level via a shared `ZMX_SESSION → pane` join.

**Architecture:** A new `@MainActor @Observable ClaudeSessionRegistry` (modeled on `PRStatusStore`) polls `claude agents --json` + batched `ps eww` on a `PollingTickerLike`, parsing inherited `ZMX_SESSION` into `[sessionName: AgentLiveness]`. A single pure merge helper folds that into pane attention (notify ping always wins) for both the Mac sidebar and the iPad/web wire model. `recordAgentStop` and `graftty notify` route through one shared `WorktreeEntry.paneSlot(forSessionName:)` join.

**Tech Stack:** Swift, Swift Testing (`@Test`/`@Suite` title-as-spec), Swift Package Manager (`swift test`), `scripts/generate-specs.py`.

**Spec doc:** `docs/superpowers/specs/2026-06-02-claude-session-registry-design.md`

---

## File Structure

**Create:**
- `Sources/GrafttyKit/AgentLiveness/AgentLiveness.swift` — the `AgentLiveness` enum (`@spec AGENT-1.0`).
- `Sources/GrafttyKit/AgentLiveness/AgentLivenessParsing.swift` — pure `(rawJSON, rawPs) → [sessionName: AgentLiveness]`.
- `Sources/GrafttyKit/AgentLiveness/AgentLivenessMerge.swift` — pure notify-wins merge helper.
- `Sources/GrafttyKit/AgentLiveness/AgentStopAttentionTarget.swift` — pure "pane vs worktree" decision for agent-stop.
- `Sources/GrafttyKit/AgentLiveness/ClaudeSessionRegistry.swift` — the polling store.
- `Tests/GrafttyTests/Specs/AgentTodo.swift` — backlog inventory (created in Task 0, drained as tasks land).
- `Tests/GrafttyTests/AgentLivenessParsingTests.swift`
- `Tests/GrafttyTests/AgentLivenessMergeTests.swift`
- `Tests/GrafttyTests/ClaudeSessionRegistryTests.swift`
- `Tests/GrafttyTests/AgentStopAttentionTargetTests.swift`
- `Tests/GrafttyTests/NotifyTargetTests.swift`

**Modify:**
- `Sources/GrafttyKit/Model/WorktreeEntry.swift` — add `paneSlot(forSessionName:)`.
- `Sources/GrafttyKit/Notification/NotificationMessage.swift` — `.notify`/`.clear` gain optional `paneSessionName`.
- `Sources/GrafttyCLI/CLI.swift` — `Notify` gains `--session` / `--worktree`; reads `$ZMX_SESSION`.
- `Sources/Graftty/GrafttyApp.swift` — instantiate registry + ticker; thread liveness into `paneLayoutNode`; route `.notify`/`.clear` pane-scoped; `recordAgentStop` pane attribution.
- `Sources/Graftty/Views/SidebarView.swift` — merge busy/idle into pane rows.

**Conventions to follow:**
- `PRStatusStore` (`Sources/GrafttyKit/PRStatus/PRStatusStore.swift`) is the template for the store.
- `CLIExecutor` protocol: `func capture(command:args:at:) async throws -> CLIOutput` where `CLIOutput = {stdout, stderr, exitCode}`.
- `PollingTickerLike`: `start(onTick:)`, `stop()`, `pulse()`.
- Specs Todo format: `@Suite("AGENT — pending specs") struct AgentTodo { @Test("""@spec AGENT-x: …""", .disabled("not yet implemented")) func agent_x() }`.

---

## Task 0: Spec inventory + commit the design doc

**Files:**
- Create: `Tests/GrafttyTests/Specs/AgentTodo.swift`

- [ ] **Step 1: Create the AGENT spec inventory**

```swift
// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("AGENT — pending specs")
struct AgentTodo {
    @Test("""
@spec AGENT-1.1: When the registry refreshes, the application shall key each claude session's busy/idle status by the `ZMX_SESSION` it inherited from its Graftty pane.
""", .disabled("not yet implemented"))
    func agent_1_1() async throws { }

    @Test("""
@spec AGENT-1.2: If a claude session reports no `ZMX_SESSION` (it is not running inside a Graftty pane), then the application shall omit it from the liveness map.
""", .disabled("not yet implemented"))
    func agent_1_2() async throws { }

    @Test("""
@spec AGENT-1.3: If a session's `ZMX_SESSION` matches no live pane, then the application shall ignore it.
""", .disabled("not yet implemented"))
    func agent_1_3() async throws { }

    @Test("""
@spec AGENT-1.4: When multiple claude sessions resolve to the same pane, the application shall report that pane as busy if any of its sessions is busy.
""", .disabled("not yet implemented"))
    func agent_1_4() async throws { }

    @Test("""
@spec AGENT-2.1: While a pane has a live `notify` attention ping, the application shall render that ping in preference to any derived busy/idle status.
""", .disabled("not yet implemented"))
    func agent_2_1() async throws { }

    @Test("""
@spec AGENT-2.2: While a pane has no live attention ping, the application shall render `working…` when its claude session is busy and render nothing when it is idle.
""", .disabled("not yet implemented"))
    func agent_2_2() async throws { }

    @Test("""
@spec AGENT-2.3: If the `claude agents --json` invocation fails or returns unparseable output, then the application shall produce an empty liveness map without crashing.
""", .disabled("not yet implemented"))
    func agent_2_3() async throws { }

    @Test("""
@spec AGENT-3.1: When an agent-stop event carries a `paneSessionName` resolving to a live pane, the application shall attach the "needs input" attention to that pane rather than the worktree.
""", .disabled("not yet implemented"))
    func agent_3_1() async throws { }

    @Test("""
@spec AGENT-3.2: If an agent-stop event has no pane session (the agent is not in a Graftty pane), then the application shall fall back to worktree-scoped "needs input" attention.
""", .disabled("not yet implemented"))
    func agent_3_2() async throws { }

    @Test("""
@spec AGENT-4.1: When `graftty notify` is given `--session <zmx-session>`, the application shall target that pane's attention overlay.
""", .disabled("not yet implemented"))
    func agent_4_1() async throws { }

    @Test("""
@spec AGENT-4.2: When `graftty notify` is given no target and `$ZMX_SESSION` is set, the application shall target the caller's pane.
""", .disabled("not yet implemented"))
    func agent_4_2() async throws { }

    @Test("""
@spec AGENT-4.3: When `graftty notify` is given no target and `$ZMX_SESSION` is unset, the application shall target the current worktree (unchanged behavior).
""", .disabled("not yet implemented"))
    func agent_4_3() async throws { }

    @Test("""
@spec AGENT-4.4: If `graftty notify` is given both `--session` and `--worktree`, then the application shall reject the invocation with a validation error.
""", .disabled("not yet implemented"))
    func agent_4_4() async throws { }
}
```

- [ ] **Step 2: Regenerate SPECS.md and confirm the AGENT section appears**

Run: `python3 scripts/generate-specs.py && git diff --stat SPECS.md`
Expected: `SPECS.md` shows new `AGENT-*` rows; script exits 0.

- [ ] **Step 3: Commit (design doc + inventory)**

```bash
git add docs/superpowers/specs/2026-06-02-claude-session-registry-design.md \
        docs/superpowers/plans/2026-06-02-claude-session-registry.md \
        Tests/GrafttyTests/Specs/AgentTodo.swift SPECS.md
git commit -m "docs(AGENT): claude session registry design, plan, and spec inventory"
```

---

## Task 1: `AgentLiveness` enum + `WorktreeEntry.paneSlot(forSessionName:)`

**Files:**
- Create: `Sources/GrafttyKit/AgentLiveness/AgentLiveness.swift`
- Modify: `Sources/GrafttyKit/Model/WorktreeEntry.swift`
- Test: `Tests/GrafttyTests/AgentStopAttentionTargetTests.swift` (reused for the join test here)

- [ ] **Step 1: Write the failing test for the join helper**

Add to a new file `Tests/GrafttyTests/PaneSlotJoinTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("@spec AGENT-1.3: paneSlot(forSessionName:) resolves a zmx session name to its pane slot or nil when unmatched.")
struct PaneSlotJoinTests {
    private func entry(with sessions: [PaneSlotID: PaneSessionID]) -> WorktreeEntry {
        var e = WorktreeEntry(path: "/tmp/wt", branch: "feature")
        e.paneSessions = sessions
        return e
    }

    @Test func resolvesMatchingSession() {
        let slot = PaneSlotID(id: UUID())
        let paneSession = PaneSessionID(id: UUID())
        let e = entry(with: [slot: paneSession])
        #expect(e.paneSlot(forSessionName: ZmxLauncher.sessionName(for: paneSession)) == slot)
    }

    @Test func returnsNilForUnknownSession() {
        let e = entry(with: [PaneSlotID(id: UUID()): PaneSessionID(id: UUID())])
        #expect(e.paneSlot(forSessionName: "graftty-deadbeef") == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PaneSlotJoinTests`
Expected: FAIL — `value of type 'WorktreeEntry' has no member 'paneSlot'`.

- [ ] **Step 3: Add the enum**

Create `Sources/GrafttyKit/AgentLiveness/AgentLiveness.swift`:

```swift
import Foundation

/// @spec AGENT-1.0
/// Liveness of a claude agent session as reported by `claude agents --json`.
/// The JSON exposes exactly two states; richer "needs input"/"completed"
/// states live only in the interactive Agent View, not the JSON.
public enum AgentLiveness: String, Codable, Sendable, Equatable {
    case busy
    case idle
}
```

- [ ] **Step 4: Add the join helper to `WorktreeEntry`**

In `Sources/GrafttyKit/Model/WorktreeEntry.swift`, add a method inside the `WorktreeEntry` struct (near the other computed helpers):

```swift
    /// Inverts `paneSessions` to find the pane slot whose zmx session name
    /// matches `sessionName` (the `ZMX_SESSION` an agent inherited). Shared
    /// by busy/idle rendering, agent-stop attribution, and `notify --session`.
    public func paneSlot(forSessionName sessionName: String) -> PaneSlotID? {
        for (slot, paneSession) in paneSessions
        where ZmxLauncher.sessionName(for: paneSession) == sessionName {
            return slot
        }
        return nil
    }
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter PaneSlotJoinTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/AgentLiveness/AgentLiveness.swift \
        Sources/GrafttyKit/Model/WorktreeEntry.swift \
        Tests/GrafttyTests/PaneSlotJoinTests.swift
git commit -m "feat(AGENT-1.0): AgentLiveness enum + WorktreeEntry.paneSlot(forSessionName:)"
```

---

## Task 2: `AgentLivenessParsing` (pure JSON+ps → liveness map)

**Files:**
- Create: `Sources/GrafttyKit/AgentLiveness/AgentLivenessParsing.swift`
- Test: `Tests/GrafttyTests/AgentLivenessParsingTests.swift`

- [ ] **Step 1: Write the failing tests** (promote AGENT-1.1, 1.2, 1.4)

```swift
import Testing
@testable import GrafttyKit

@Suite("@spec AGENT-1.1: parse claude agents --json + ps env into busy/idle keyed by inherited ZMX_SESSION.")
struct AgentLivenessParsingTests {
    let json = """
    [ {"pid": 100, "cwd": "/a", "kind": "interactive", "sessionId": "s1", "startedAt": 1, "status": "busy"},
      {"pid": 200, "cwd": "/b", "kind": "interactive", "sessionId": "s2", "startedAt": 1, "status": "idle"} ]
    """
    // `ps eww -o pid=,command=` style: "<pid> <cmd-and-env words>"
    let ps = """
    100 claude ZMX_SESSION=graftty-aaaa1111 GRAFTTY_SOCK=/x
    200 claude ZMX_SESSION=graftty-bbbb2222
    """

    @Test func parsesBusyIdleKeyedBySession() {
        let map = AgentLivenessParsing.liveness(agentsJSON: json, psOutput: ps)
        #expect(map["graftty-aaaa1111"] == .busy)
        #expect(map["graftty-bbbb2222"] == .idle)
    }

    @Test("@spec AGENT-1.2: a session with no ZMX_SESSION is omitted.")
    func dropsSessionsWithoutZmxSession() {
        let psNoEnv = "100 claude --some-flag\n200 claude ZMX_SESSION=graftty-bbbb2222"
        let map = AgentLivenessParsing.liveness(agentsJSON: json, psOutput: psNoEnv)
        #expect(map["graftty-bbbb2222"] == .idle)
        #expect(map.count == 1)
    }

    @Test("@spec AGENT-1.4: when two sessions share a pane, busy wins.")
    func busyWinsWithinPane() {
        let json2 = """
        [ {"pid": 100, "cwd": "/a", "kind": "interactive", "sessionId": "s1", "startedAt": 1, "status": "idle"},
          {"pid": 200, "cwd": "/a", "kind": "interactive", "sessionId": "s2", "startedAt": 1, "status": "busy"} ]
        """
        let ps2 = "100 claude ZMX_SESSION=graftty-aaaa1111\n200 claude ZMX_SESSION=graftty-aaaa1111"
        let map = AgentLivenessParsing.liveness(agentsJSON: json2, psOutput: ps2)
        #expect(map["graftty-aaaa1111"] == .busy)
    }

    @Test("@spec AGENT-2.3: malformed JSON yields an empty map, no throw.")
    func malformedJsonIsEmpty() {
        #expect(AgentLivenessParsing.liveness(agentsJSON: "not json", psOutput: ps).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter AgentLivenessParsingTests`
Expected: FAIL — no `AgentLivenessParsing`.

- [ ] **Step 3: Implement the pure parser**

Create `Sources/GrafttyKit/AgentLiveness/AgentLivenessParsing.swift`:

```swift
import Foundation

/// Pure transform: raw `claude agents --json` + raw `ps eww -o pid=,command=`
/// output → `[zmxSessionName: AgentLiveness]`. No I/O, no throwing — bad
/// input collapses to an empty map (@spec AGENT-2.3).
public enum AgentLivenessParsing {
    private struct Session: Decodable {
        let pid: Int
        let status: String
    }

    public static func liveness(agentsJSON: String, psOutput: String) -> [String: AgentLiveness] {
        guard let data = agentsJSON.data(using: .utf8),
              let sessions = try? JSONDecoder().decode([Session].self, from: data)
        else { return [:] }

        let sessionByPID = sessionNameByPID(psOutput)
        var result: [String: AgentLiveness] = [:]
        for s in sessions {
            guard let name = sessionByPID[s.pid] else { continue }   // AGENT-1.2 / 1.3
            let live: AgentLiveness = (s.status == "busy") ? .busy : .idle
            // AGENT-1.4: busy wins when multiple sessions share a pane.
            if result[name] == .busy { continue }
            result[name] = live
        }
        return result
    }

    /// Extracts `ZMX_SESSION=graftty-…` per pid from `ps eww` lines of the
    /// form "<pid> <command and env tokens>". The session token is space-free.
    private static func sessionNameByPID(_ psOutput: String) -> [Int: String] {
        var out: [Int: String] = [:]
        for line in psOutput.split(separator: "\n") {
            let tokens = line.split(separator: " ")
            guard let first = tokens.first, let pid = Int(first) else { continue }
            for token in tokens.dropFirst() where token.hasPrefix("ZMX_SESSION=") {
                out[pid] = String(token.dropFirst("ZMX_SESSION=".count))
                break
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter AgentLivenessParsingTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Promote specs & regenerate**

Delete the `agent_1_1`, `agent_1_2`, `agent_1_4` entries from `Tests/GrafttyTests/Specs/AgentTodo.swift` (now live in real tests). Leave `agent_1_3` (covered by PaneSlotJoinTests' suite title — also delete `agent_1_3`). Then:

Run: `python3 scripts/generate-specs.py`
Expected: exit 0, no "duplicate spec id" error.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/AgentLiveness/AgentLivenessParsing.swift \
        Tests/GrafttyTests/AgentLivenessParsingTests.swift \
        Tests/GrafttyTests/Specs/AgentTodo.swift SPECS.md
git commit -m "feat(AGENT-1.1..1.4): pure AgentLivenessParsing of claude agents --json + ps env"
```

---

## Task 3: `AgentLivenessMerge` (notify-wins, shared by both surfaces)

**Files:**
- Create: `Sources/GrafttyKit/AgentLiveness/AgentLivenessMerge.swift`
- Test: `Tests/GrafttyTests/AgentLivenessMergeTests.swift`

- [ ] **Step 1: Write the failing tests** (promote AGENT-2.1, 2.2)

```swift
import Testing
@testable import GrafttyKit

@Suite("@spec AGENT-2.1/2.2: pane attention merge — live notify ping wins; else busy→working…, idle→nil.")
struct AgentLivenessMergeTests {
    @Test func notifyPingWinsOverBusy() {
        let text = AgentLivenessMerge.effectivePaneText(
            paneAttentionText: "build failed",
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .busy])
        #expect(text == "build failed")
    }

    @Test func busyRendersWorkingWhenNoPing() {
        let text = AgentLivenessMerge.effectivePaneText(
            paneAttentionText: nil,
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .busy])
        #expect(text == "working…")
    }

    @Test func idleRendersNothing() {
        let text = AgentLivenessMerge.effectivePaneText(
            paneAttentionText: nil,
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .idle])
        #expect(text == nil)
    }

    @Test func unknownSessionRendersNothing() {
        #expect(AgentLivenessMerge.effectivePaneText(
            paneAttentionText: nil, sessionName: nil, liveness: [:]) == nil)
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter AgentLivenessMergeTests`
Expected: FAIL — no `AgentLivenessMerge`.

- [ ] **Step 3: Implement**

Create `Sources/GrafttyKit/AgentLiveness/AgentLivenessMerge.swift`:

```swift
import Foundation

/// The single notify-wins merge used by both render surfaces (Mac sidebar
/// and the iPad/web wire model). A live `notify` ping always wins; derived
/// busy/idle only fills the gap. Idle shows nothing to avoid visual noise.
public enum AgentLivenessMerge {
    public static let busyText = "working…"

    public static func effectivePaneText(
        paneAttentionText: String?,
        sessionName: String?,
        liveness: [String: AgentLiveness]
    ) -> String? {
        if let paneAttentionText { return paneAttentionText }   // AGENT-2.1
        guard let sessionName, liveness[sessionName] == .busy else { return nil }
        return busyText                                          // AGENT-2.2
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter AgentLivenessMergeTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Promote AGENT-2.1, 2.2 out of AgentTodo.swift; regenerate**

Run: `python3 scripts/generate-specs.py`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/AgentLiveness/AgentLivenessMerge.swift \
        Tests/GrafttyTests/AgentLivenessMergeTests.swift \
        Tests/GrafttyTests/Specs/AgentTodo.swift SPECS.md
git commit -m "feat(AGENT-2.1/2.2): shared notify-wins pane attention merge"
```

---

## Task 4: `ClaudeSessionRegistry` polling store

**Files:**
- Create: `Sources/GrafttyKit/AgentLiveness/ClaudeSessionRegistry.swift`
- Test: `Tests/GrafttyTests/ClaudeSessionRegistryTests.swift`

**Notes:** Use a fake `CLIExecutor` returning canned `CLIOutput`. The registry runs two `capture(...)` calls per refresh: first `claude agents --json`, then `ps eww -o pid=,command= -p <csv>`. The fake matches on `command`.

- [ ] **Step 1: Write the failing tests** (promote AGENT-2.3 refresh-level)

```swift
import Testing
import Foundation
@testable import GrafttyKit

private struct FakeExecutor: CLIExecutor {
    let outputs: [String: CLIOutput]   // keyed by command basename
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try capture(command: command, args: args, at: directory)
    }
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        outputs[command] ?? CLIOutput(stdout: "", stderr: "", exitCode: 0)
    }
}

@MainActor
@Suite("@spec AGENT-2.3: ClaudeSessionRegistry refresh populates liveness and survives failure.")
struct ClaudeSessionRegistryTests {
    private func registry(json: String, ps: String, claudeCmd: String = "claude")
        -> ClaudeSessionRegistry {
        let exec = FakeExecutor(outputs: [
            claudeCmd: CLIOutput(stdout: json, stderr: "", exitCode: 0),
            "ps": CLIOutput(stdout: ps, stderr: "", exitCode: 0),
        ])
        return ClaudeSessionRegistry(executor: exec, claudePath: claudeCmd)
    }

    @Test func refreshPopulatesLiveness() async {
        let r = registry(
            json: #"[{"pid":100,"cwd":"/a","kind":"interactive","sessionId":"s","startedAt":1,"status":"busy"}]"#,
            ps: "100 claude ZMX_SESSION=graftty-aaaa1111")
        await r.refresh()
        #expect(r.livenessBySession["graftty-aaaa1111"] == .busy)
    }

    @Test func failedClaudeYieldsEmpty() async {
        let exec = FakeExecutor(outputs: [
            "claude": CLIOutput(stdout: "", stderr: "boom", exitCode: 1),
        ])
        let r = ClaudeSessionRegistry(executor: exec, claudePath: "claude")
        await r.refresh()
        #expect(r.livenessBySession.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter ClaudeSessionRegistryTests`
Expected: FAIL — no `ClaudeSessionRegistry`.

- [ ] **Step 3: Implement the store**

Create `Sources/GrafttyKit/AgentLiveness/ClaudeSessionRegistry.swift`:

```swift
import Foundation
import Observation
import os

/// Polls `claude agents --json` (+ a batched `ps eww` to recover each
/// session's inherited `ZMX_SESSION`) and exposes per-pane busy/idle.
/// Read-only with respect to Claude Code. Modeled on `PRStatusStore`.
@MainActor
@Observable
public final class ClaudeSessionRegistry {
    public private(set) var livenessBySession: [String: AgentLiveness] = [:]

    @ObservationIgnored private let executor: CLIExecutor
    @ObservationIgnored private let claudePath: String
    @ObservationIgnored private var ticker: PollingTickerLike?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let logger =
        Logger(subsystem: "com.btucker.graftty", category: "ClaudeSessionRegistry")

    public init(executor: CLIExecutor = CLIRunner(), claudePath: String = "claude") {
        self.executor = executor
        self.claudePath = claudePath
    }

    /// Begin polling on the supplied ticker (the app wires the real
    /// `PollingTicker`; tests call `refresh()` directly).
    public func start(ticker: PollingTickerLike) {
        self.ticker = ticker
        ticker.start { [weak self] in await self?.refresh() }
    }

    public func stop() { ticker?.stop(); ticker = nil }

    /// One poll cycle. A stuck/superseded poll's late write is dropped via
    /// the generation token. Failure collapses to an empty map (AGENT-2.3).
    public func refresh() async {
        generation += 1
        let mine = generation
        let map = await Self.poll(executor: executor, claudePath: claudePath, logger: logger)
        guard mine == generation else { return }
        if livenessBySession != map { livenessBySession = map }
    }

    private static func poll(
        executor: CLIExecutor, claudePath: String, logger: Logger
    ) async -> [String: AgentLiveness] {
        do {
            let agents = try await executor.capture(
                command: claudePath, args: ["agents", "--json"], at: ".")
            guard agents.exitCode == 0 else { return [:] }
            let pids = pidList(from: agents.stdout)
            guard !pids.isEmpty else { return [:] }
            let ps = try await executor.capture(
                command: "ps",
                args: ["eww", "-o", "pid=,command=", "-p", pids.joined(separator: ",")],
                at: ".")
            return AgentLivenessParsing.liveness(agentsJSON: agents.stdout, psOutput: ps.stdout)
        } catch {
            logger.debug("claude agents poll failed: \(String(describing: error))")
            return [:]
        }
    }

    private static func pidList(from json: String) -> [String] {
        struct S: Decodable { let pid: Int }
        guard let data = json.data(using: .utf8),
              let sessions = try? JSONDecoder().decode([S].self, from: data)
        else { return [] }
        return sessions.map { String($0.pid) }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ClaudeSessionRegistryTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Promote AGENT-2.3 out of AgentTodo.swift; regenerate**

Run: `python3 scripts/generate-specs.py`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/AgentLiveness/ClaudeSessionRegistry.swift \
        Tests/GrafttyTests/ClaudeSessionRegistryTests.swift \
        Tests/GrafttyTests/Specs/AgentTodo.swift SPECS.md
git commit -m "feat(AGENT-2.3): ClaudeSessionRegistry polling store (claude agents --json + ps)"
```

---

## Task 5: Wire busy/idle into both render surfaces

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift` (instantiate registry + ticker; thread liveness into `paneLayoutNode`)
- Modify: `Sources/Graftty/Views/SidebarView.swift` (merge into pane rows)

**No new tests** (the merge + parse logic is already covered; this is wiring against `@MainActor` UI not exercised by `swift test` on macOS — confirm via build + manual run).

- [ ] **Step 1: Add the registry property + init**

In `Sources/Graftty/GrafttyApp.swift`, beside `let prStatusStore: PRStatusStore` (≈ line 134):

```swift
    let claudeSessionRegistry: ClaudeSessionRegistry
```

In the initializer, beside `self.prStatusStore = PRStatusStore(...)` (≈ line 183):

```swift
        self.claudeSessionRegistry = ClaudeSessionRegistry()
```

- [ ] **Step 2: Start a 2s ticker**

Near the other tickers (the `prTicker` block ≈ line 900), add:

```swift
        let claudeAgentsTicker = PollingTicker(interval: .seconds(2))
        claudeSessionRegistry.start(ticker: claudeAgentsTicker)
```

(Keep a stored reference if the surrounding tickers are stored as properties; follow the exact pattern used by `prTicker`/`presenceTicker` in that method.)

- [ ] **Step 3: Thread liveness into the wire-model builder**

Change `paneLayoutNode` (≈ line 3349) to accept the liveness map and merge:

```swift
@MainActor
private func paneLayoutNode(
    from node: SplitTree.Node,
    paneSessions: [PaneSlotID: PaneSessionID],
    titles: [PaneSlotID: String],
    paneAttention: [PaneSlotID: Attention],
    liveness: [String: AgentLiveness]
) -> PaneLayoutNode {
    switch node {
    case let .leaf(id):
        let sessionName = paneSessions[id].map(ZmxLauncher.sessionName(for:))
        return .leaf(
            sessionName: sessionName ?? "",
            title: titles[id] ?? "",
            attentionText: AgentLivenessMerge.effectivePaneText(
                paneAttentionText: paneAttention[id]?.text,
                sessionName: sessionName,
                liveness: liveness)
        )
    case let .split(s):
        return .split(
            direction: s.direction == .horizontal ? .horizontal : .vertical,
            ratio: s.ratio,
            left: paneLayoutNode(from: s.left, paneSessions: paneSessions,
                                 titles: titles, paneAttention: paneAttention, liveness: liveness),
            right: paneLayoutNode(from: s.right, paneSessions: paneSessions,
                                  titles: titles, paneAttention: paneAttention, liveness: liveness)
        )
    }
}
```

At the call site (≈ line 1224), pass `liveness: claudeSessionRegistry.livenessBySession`.

- [ ] **Step 4: Merge into the Mac sidebar pane rows**

In `Sources/Graftty/Views/SidebarView.swift` (≈ line 290, the `PaneTitleRow(...)` construction), change `attentionText:` to merge. The view needs access to `appState.claudeSessionRegistry.livenessBySession` and the leaf's session name:

```swift
                        PaneTitleRow(
                            title: terminalManager.displayTitle(for: terminalID),
                            isActiveWorktree: isActive,
                            isFocusedPane: isActive
                                && worktree.focusedPaneSlotID == terminalID,
                            theme: theme,
                            attentionText: AgentLivenessMerge.effectivePaneText(
                                paneAttentionText: attention.paneCapsules[terminalID],
                                sessionName: worktree.paneSessions[terminalID]
                                    .map(ZmxLauncher.sessionName(for:)),
                                liveness: claudeSessionRegistry.livenessBySession),
                            portBindings: portBindings.bindings[terminalID] ?? []
                        )
```

Add a `claudeSessionRegistry` reference to the view (pass it down from where `attention`/`portBindings` are provided; mirror how `portBindings` is threaded into `SidebarView`).

- [ ] **Step 5: Build + manual smoke**

Run: `swift build`
Expected: builds clean.
Then run the app (`/run` or `swift run Graftty`), open a worktree with a running claude pane, confirm a "working…" capsule appears on the pane row while claude is mid-turn and disappears when idle.

- [ ] **Step 6: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift Sources/Graftty/Views/SidebarView.swift
git commit -m "feat(AGENT-2.x): surface pane busy/idle in sidebar + iPad wire model"
```

---

## Task 6: Re-home agent "needs input" to the pane

**Files:**
- Create: `Sources/GrafttyKit/AgentLiveness/AgentStopAttentionTarget.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift` (`recordAgentStop` + `handleTeamHook` call site)
- Test: `Tests/GrafttyTests/AgentStopAttentionTargetTests.swift`

- [ ] **Step 1: Write the failing tests** (promote AGENT-3.1, 3.2)

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("@spec AGENT-3.1/3.2: agent-stop attention targets the pane when resolvable, else the worktree.")
struct AgentStopAttentionTargetTests {
    private func entry(slot: PaneSlotID, session: PaneSessionID) -> WorktreeEntry {
        var e = WorktreeEntry(path: "/tmp/wt", branch: "feature")
        e.paneSessions = [slot: session]
        return e
    }

    @Test func targetsPaneWhenSessionResolves() {
        let slot = PaneSlotID(id: UUID()); let s = PaneSessionID(id: UUID())
        let e = entry(slot: slot, session: s)
        let target = AgentStopAttentionTarget.resolve(
            worktree: e, paneSessionName: ZmxLauncher.sessionName(for: s))
        #expect(target == .pane(slot))
    }

    @Test func fallsBackToWorktreeWhenNoSession() {
        let e = entry(slot: PaneSlotID(id: UUID()), session: PaneSessionID(id: UUID()))
        #expect(AgentStopAttentionTarget.resolve(worktree: e, paneSessionName: nil) == .worktree)
        #expect(AgentStopAttentionTarget.resolve(
            worktree: e, paneSessionName: "graftty-nomatch") == .worktree)
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter AgentStopAttentionTargetTests`
Expected: FAIL — no `AgentStopAttentionTarget`.

- [ ] **Step 3: Implement the pure decision**

Create `Sources/GrafttyKit/AgentLiveness/AgentStopAttentionTarget.swift`:

```swift
import Foundation

/// Where an agent-stop "needs input" overlay should land: the agent's pane
/// when its session resolves, otherwise the worktree (agent not in a pane).
public enum AgentStopAttentionTarget: Equatable {
    case pane(PaneSlotID)
    case worktree

    public static func resolve(worktree: WorktreeEntry, paneSessionName: String?) -> AgentStopAttentionTarget {
        if let name = paneSessionName, let slot = worktree.paneSlot(forSessionName: name) {
            return .pane(slot)
        }
        return .worktree
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter AgentStopAttentionTargetTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Pass `paneSessionName` through and apply the target**

In `Sources/Graftty/GrafttyApp.swift`, update the `recordAgentStop` call inside `handleTeamHook` (the `if event == .stop` block) to forward `paneSessionName`:

```swift
            if event == .stop {
                recordAgentStop(
                    callerPath: callerPath,
                    runtime: runtime,
                    sessionID: sessionID,
                    paneSessionName: paneSessionName,
                    appState: appState
                )
            }
```

Then change `recordAgentStop`'s signature and the attention write:

```swift
    @MainActor
    private static func recordAgentStop(
        callerPath: String,
        runtime: TeamHookRuntime,
        sessionID: String?,
        paneSessionName: String?,
        appState: Binding<AppState>
    ) {
        let timestamp = Date()
        for repoIndex in appState.wrappedValue.repos.indices {
            for worktreeIndex in appState.wrappedValue.repos[repoIndex].worktrees.indices
                where appState.wrappedValue.repos[repoIndex].worktrees[worktreeIndex].path == callerPath {
                let worktree = appState.wrappedValue.repos[repoIndex].worktrees[worktreeIndex]
                let worktreeName = WorktreeNameSanitizer.sanitize(worktree.branch)
                let resolvedSessionID = sessionID ?? "\(runtime.rawValue):\(worktreeName):\(callerPath)"
                let attention = Attention(
                    text: "\(AgentStopNotification.displayName(runtime)) needs input",
                    timestamp: timestamp)
                switch AgentStopAttentionTarget.resolve(worktree: worktree, paneSessionName: paneSessionName) {
                case let .pane(slot):
                    appState.wrappedValue.repos[repoIndex].worktrees[worktreeIndex]
                        .paneAttention[slot] = attention
                case .worktree:
                    appState.wrappedValue.repos[repoIndex].worktrees[worktreeIndex]
                        .attention = attention
                }
                AgentNotificationRouter.shared.post(
                    AgentStopNotification.content(
                        runtime: runtime, worktreeName: worktreeName,
                        worktreePath: callerPath, sessionID: resolvedSessionID,
                        timestamp: timestamp))
                return
            }
        }
    }
```

- [ ] **Step 6: Build, promote specs, regenerate, commit**

Run: `swift build && swift test --filter AgentStopAttentionTargetTests`
Expected: PASS. Delete `agent_3_1`, `agent_3_2` from `AgentTodo.swift`; run `python3 scripts/generate-specs.py`.

```bash
git add Sources/GrafttyKit/AgentLiveness/AgentStopAttentionTarget.swift \
        Sources/Graftty/GrafttyApp.swift \
        Tests/GrafttyTests/AgentStopAttentionTargetTests.swift \
        Tests/GrafttyTests/Specs/AgentTodo.swift SPECS.md
git commit -m "feat(AGENT-3.1/3.2): attribute agent needs-input to the agent's pane"
```

---

## Task 7: `graftty notify --session/--worktree` + pane-scoped notify

**Files:**
- Modify: `Sources/GrafttyKit/Notification/NotificationMessage.swift` (`.notify`/`.clear` gain optional `paneSessionName`)
- Modify: `Sources/GrafttyCLI/CLI.swift` (`Notify` command)
- Modify: `Sources/Graftty/GrafttyApp.swift` (`.notify`/`.clear` handler resolves the slot)
- Test: `Tests/GrafttyTests/NotifyTargetTests.swift`

**Notes:** `.notify(path:text:clearAfter:)` becomes `.notify(path:text:clearAfter:paneSessionName:)` (default `nil`); add the `pane_session_name` key to encode/decode via `encodeIfPresent`/`decodeIfPresent` mirroring the existing `.teamHook` handling. `.clear(path:)` becomes `.clear(path:paneSessionName:)`.

- [ ] **Step 1: Write the failing tests** (promote AGENT-4.1..4.4 — message build + validation)

```swift
import Testing
@testable import GrafttyKit
@testable import GrafttyCLI

@Suite("@spec AGENT-4.x: graftty notify target grammar maps flags/env to pane- or worktree-scoped messages.")
struct NotifyTargetTests {
    @Test("@spec AGENT-4.1: --session targets a pane.")
    func sessionFlagTargetsPane() throws {
        let msg = try NotifyTarget.message(
            text: "done", session: "graftty-aaaa1111", worktree: nil,
            env: [:], resolveWorktreePath: { "/wt" })
        #expect(msg == .notify(path: "/wt", text: "done", clearAfter: nil,
                               paneSessionName: "graftty-aaaa1111"))
    }

    @Test("@spec AGENT-4.2: no flag + ZMX_SESSION targets caller pane.")
    func envTargetsCallerPane() throws {
        let msg = try NotifyTarget.message(
            text: "done", session: nil, worktree: nil,
            env: ["ZMX_SESSION": "graftty-bbbb2222"], resolveWorktreePath: { "/wt" })
        #expect(msg == .notify(path: "/wt", text: "done", clearAfter: nil,
                               paneSessionName: "graftty-bbbb2222"))
    }

    @Test("@spec AGENT-4.3: no flag + no env stays worktree-scoped.")
    func noTargetStaysWorktree() throws {
        let msg = try NotifyTarget.message(
            text: "done", session: nil, worktree: nil,
            env: [:], resolveWorktreePath: { "/wt" })
        #expect(msg == .notify(path: "/wt", text: "done", clearAfter: nil, paneSessionName: nil))
    }

    @Test("@spec AGENT-4.4: --session and --worktree are mutually exclusive.")
    func sessionAndWorktreeConflict() {
        #expect(throws: NotifyTargetError.conflictingTargets) {
            _ = try NotifyTarget.message(
                text: "done", session: "graftty-aaaa1111", worktree: "other",
                env: [:], resolveWorktreePath: { "/wt" })
        }
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter NotifyTargetTests`
Expected: FAIL — no `NotifyTarget`.

- [ ] **Step 3: Extend the wire message**

In `Sources/GrafttyKit/Notification/NotificationMessage.swift`:
- Change the case: `case notify(path: String, text: String, clearAfter: TimeInterval? = nil, paneSessionName: String? = nil)` and `case clear(path: String, paneSessionName: String? = nil)`.
- In `encode(to:)` for `.notify`/`.clear`, add `try container.encodeIfPresent(paneSessionName, forKey: .paneSessionName)`.
- In `init(from:)` for `"notify"`/`"clear"`, add `let paneSessionName = try container.decodeIfPresent(String.self, forKey: .paneSessionName)` and pass it.
(The `paneSessionName`/`pane_session_name` CodingKey already exists — used by `.teamHook`.)

- [ ] **Step 4: Implement the CLI target resolver**

Create `Sources/GrafttyCLI/NotifyTarget.swift`:

```swift
import Foundation
import GrafttyKit

public enum NotifyTargetError: Error, Equatable { case conflictingTargets }

/// Pure mapping of `graftty notify` flags + environment to a wire message.
/// `--session` → pane-scoped; `--worktree` → that worktree; no flag with
/// `$ZMX_SESSION` → caller pane; no flag without it → CWD worktree.
public enum NotifyTarget {
    public static func message(
        text: String,
        session: String?,
        worktree: String?,
        env: [String: String],
        resolveWorktreePath: () throws -> String,
        clearAfter: TimeInterval? = nil
    ) throws -> NotificationMessage {
        if session != nil && worktree != nil { throw NotifyTargetError.conflictingTargets }
        let path = try resolveWorktreePath()
        let pane = session ?? (worktree == nil ? env["ZMX_SESSION"] : nil)
        return .notify(path: path, text: text, clearAfter: clearAfter, paneSessionName: pane)
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter NotifyTargetTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Wire the `Notify` command to use it**

In `Sources/GrafttyCLI/CLI.swift`, add to `struct Notify`:

```swift
    @Option(name: .long, help: "Target a specific pane by its zmx session name")
    var session: String?

    @Option(name: .long, help: "Target a specific worktree by name")
    var worktree: String?
```

Replace `run()`'s message construction:

```swift
    func run() throws {
        let message: NotificationMessage
        if clear {
            let path = try resolveTargetWorktreePath()
            let pane = session ?? (worktree == nil ? ProcessInfo.processInfo.environment["ZMX_SESSION"] : nil)
            message = .clear(path: path, paneSessionName: pane)
        } else {
            message = try NotifyTarget.message(
                text: text!, session: session, worktree: worktree,
                env: ProcessInfo.processInfo.environment,
                resolveWorktreePath: { try resolveTargetWorktreePath() },
                clearAfter: clearAfter.map { TimeInterval($0) })
        }
        try CLIEnv.sendFireAndForget(message)
    }

    private func resolveTargetWorktreePath() throws -> String {
        if let worktree, let path = WorktreeResolver.resolveWorktreeName(worktree, stateDirectory: AppState.defaultDirectory) {
            return path
        }
        return try CLIEnv.resolveWorktree()
    }
```

(Keep the existing `validate()`; `NotifyTarget`'s conflict check is also enforced at run time.)

- [ ] **Step 7: Resolve the slot in the app handler**

In `Sources/Graftty/GrafttyApp.swift`, in the `.notify` socket handler (≈ line 1796) and `.clear` handler (≈ line 1816): when `paneSessionName` is non-nil, resolve `worktree.paneSlot(forSessionName:)` and write/clear `paneAttention[slot]` (reuse `setAttentionForTerminal` for the auto-clear path); otherwise keep the existing worktree-scoped write. Match on the worktree by `path` first, then branch on `paneSessionName`.

- [ ] **Step 8: Build, promote specs, regenerate, commit**

Run: `swift build && swift test --filter NotifyTargetTests`
Expected: PASS. Delete `agent_4_1..4_4` from `AgentTodo.swift`; `python3 scripts/generate-specs.py`.

```bash
git add Sources/GrafttyKit/Notification/NotificationMessage.swift \
        Sources/GrafttyCLI/CLI.swift Sources/GrafttyCLI/NotifyTarget.swift \
        Sources/Graftty/GrafttyApp.swift \
        Tests/GrafttyTests/NotifyTargetTests.swift \
        Tests/GrafttyTests/Specs/AgentTodo.swift SPECS.md
git commit -m "feat(AGENT-4.x): graftty notify --session/--worktree pane-scoped targeting"
```

---

## Task 8: Full verification + SPECS sync

- [ ] **Step 1: Whole suite green**

Run: `swift test 2>&1 | tail -20`
Expected: all tests pass; no AGENT spec is both active and disabled.

- [ ] **Step 2: SPECS.md not stale**

Run: `python3 scripts/generate-specs.py --check`
Expected: exit 0 ("SPECS.md up to date").

- [ ] **Step 3: /simplify the diff**

Invoke `/simplify` over the branch diff; apply reuse/altitude cleanups it surfaces (CLAUDE.md requires this before a PR).

- [ ] **Step 4: Commit any simplifications**

```bash
git add -A && git commit -m "refactor(AGENT): simplify per /simplify" || echo "nothing to simplify"
```

---

## Self-Review (completed against the spec)

- **Spec coverage:** AGENT-1.0 (Task 1), 1.1–1.4 (Tasks 1–2), 2.1–2.3 (Tasks 3–4), pane surfacing (Task 5), 3.1–3.2 (Task 6), 4.1–4.4 (Task 7). Component 7 (consolidation) and Component 8 (auto-clear) are spec non-core/optional and intentionally deferred — noted in the spec; not in this plan's critical path.
- **Type consistency:** `AgentLiveness`, `AgentLivenessParsing.liveness(agentsJSON:psOutput:)`, `AgentLivenessMerge.effectivePaneText(paneAttentionText:sessionName:liveness:)`, `WorktreeEntry.paneSlot(forSessionName:)`, `AgentStopAttentionTarget.resolve(worktree:paneSessionName:)`, `NotifyTarget.message(...)` are used identically across tasks.
- **Placeholder scan:** every code step carries complete code; wiring steps (Task 5, Task 7 step 7) reference exact files/line anchors and the helper signatures defined earlier.

> **Note for executor:** macOS `swift test` does not exercise iOS-guarded code; Task 5's pane-pill rendering on iPad rides the shared `panes_state` wire model and must be confirmed on iOS CI, not just locally.
