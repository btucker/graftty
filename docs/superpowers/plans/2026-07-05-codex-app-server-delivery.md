# Codex App-Server Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Codex team inbox delivery through zmx/PTY nudges with Codex app-server turn delivery.

**Architecture:** The Codex wrapper starts one Codex app-server per wrapped Codex TUI process, launches the TUI with `--remote unix://<socket>`, and registers the app-server socket with Graftty. The app watches team inbox appends, resolves the single owning live Codex presence record, validates the registered app-server has exactly one loaded thread for the target worktree, then sends a `turn/start` through the app-server proxy and advances the worktree watermark only after acceptance. There is no zmx fallback.

**Tech Stack:** Swift 5.10, Swift Testing, `GrafttyKit`, `GrafttyCLI`, Codex app-server JSON-RPC over `codex app-server proxy --sock`, existing `TeamInbox`, `TeamPresenceStorage`, `TeamDeliveryOwnershipResolver`, and `TeamInboxObserver`.

---

## Context

Current `origin/main` has the inbox and ownership scaffolding, but not Codex app-server transport:

- `AgentHookInstaller.wrapperScript(runtime: .codex, ...)` only runs `internal sync-codex-home` and then `env CODEX_HOME=<mirror> "$real_binary" "$@"`.
- `GrafttyApp.startup()` wires `IdleDeliveryService` to `ZmxNudgeSender`, which writes formatted team messages into the pane PTY.
- `TeamInboxRequestHandler` still contains hook-bound urgent delivery behavior for `post-tool-use`, while `stop` only updates idle state.
- The June 18 delivery ownership plan explicitly deferred Codex app-server delivery.

Local Codex CLI support was verified on July 5, 2026:

- `codex app-server --listen unix://PATH`
- `codex --remote unix://PATH`
- `codex app-server proxy --sock PATH`
- JSON-RPC methods include `initialize`, `thread/loaded/list`, `thread/read`, and `turn/start`.
- `thread/loaded/list` returns thread ids currently loaded in that app-server process. Starting one app-server per wrapped Codex pane lets Graftty avoid guessing the visible thread from global historical thread lists.

## Non-Goals

- Do not use `post-tool-use` or `stop` for Codex message delivery.
- Do not write team messages into the Codex PTY through zmx.
- Do not fall back to zmx if app-server validation fails.
- Do not deliver to a historical thread found only via `thread/list`.
- Do not change Claude delivery semantics except where shared event names or removed Codex-only callbacks require cleanup.

## File Structure

- Create `Sources/GrafttyKit/Teams/CodexAppServerSession.swift`
  - Defines `CodexAppServerSessionRecord` and `CodexAppServerSessionStorage`.
  - Stores per `(teamID, worktree, paneSessionName)` app-server socket metadata.
  - Cleans stale records by app-server PID/process identity.
- Create `Sources/GrafttyKit/Teams/CodexAppServerClient.swift`
  - Defines `CodexAppServerClienting` and production `CodexAppServerClient`.
  - Talks to `codex app-server proxy --sock <socket>`.
  - Performs `thread/loaded/list`, `thread/read`, and `turn/start`.
- Create `Sources/GrafttyKit/Teams/CodexAppServerDeliveryService.swift`
  - Actor that reads unread inbox rows, resolves owner presence + app-server record, calls the client, writes worktree watermark, and logs attempts.
- Modify `Sources/GrafttyKit/Teams/AgentHookInstaller.swift`
  - Codex wrapper starts app-server and launches Codex TUI with `--remote unix://<socket>`.
  - Wrapper registers/unregisters app-server metadata.
- Modify `Sources/GrafttyCLI/Team.swift`
  - Add nested `team codex-app-server register` and `team codex-app-server unregister`.
- Modify `Sources/GrafttyKit/Teams/TeamEventLog.swift`
  - Replace or supplement Codex zmx attempt logging with `codexAppServerDeliveryAttempt`.
- Modify `Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift`
  - Remove Codex `onStop` delivery callback invocation and Codex urgent `post-tool-use` message delivery.
  - Keep Claude hook behavior unchanged.
- Modify `Sources/Graftty/GrafttyApp.swift`
  - Remove `IdleDeliveryService`, `ZmxNudgeSender`, `EngagedGraceScheduler` delivery wiring, and Codex stop delivery plan usage.
  - Wire `TeamInboxObserver` to `CodexAppServerDeliveryService.onMessageArrival(team:worktree:)`.
- Delete or rewrite `Sources/GrafttyKit/Teams/IdleDeliveryService.swift`
  - The zmx nudge service should not remain as a production delivery path.
- Modify `Sources/GrafttyKit/Teams/TeamHookRenderer.swift`
  - Remove comments that describe `IdleDeliveryService` as the mid-session Codex delivery path.
- Modify `Sources/GrafttyKit/Teams/TeamInbox.swift`
  - Keep `TeamInboxWorktreeWatermark`; remove `zmxWatermark` APIs only if no non-delivery code still needs migration support.
- Tests:
  - Create `Tests/GrafttyKitTests/Teams/CodexAppServerSessionStorageTests.swift`
  - Create `Tests/GrafttyKitTests/Teams/CodexAppServerClientTests.swift`
  - Create `Tests/GrafttyTests/Specs/CodexAppServerDeliveryTests.swift`
  - Modify `Tests/GrafttyTests/Specs/AgentHookInstallerWrapperTests.swift`
  - Modify `Tests/GrafttyKitTests/Teams/TeamInboxRequestHandlerTests.swift`
  - Modify `Tests/GrafttyKitTests/Teams/TeamEventLogTests.swift`
  - Delete or replace `Tests/GrafttyTests/Specs/IdleDeliveryTests.swift`
  - Delete or replace `Tests/GrafttyKitTests/Teams/IdleDeliveryEndToEndTests.swift`
  - Delete `Tests/GrafttyKitTests/Teams/ZmxNudgeSenderTests.swift`
  - Delete or replace `Tests/GrafttyKitTests/Teams/TeamInboxZmxWatermarkTests.swift` if `zmxWatermark` APIs are removed.

## Delivery Rules

Codex app-server delivery must satisfy all of these before advancing watermarks:

1. The recipient worktree has a live owner presence record for `runtime == .codex`.
2. The owner presence record has a `paneSessionName`.
3. A live `CodexAppServerSessionRecord` exists for that exact `(teamID, worktree, paneSessionName)`.
4. `thread/loaded/list` on that app-server returns exactly one loaded thread id.
5. `thread/read` for that id returns a thread whose `cwd` exactly equals the recipient worktree.
6. `turn/start` is accepted by the app-server.

Failure at any step logs `codexAppServerDeliveryAttempt` and leaves the message unread. There is no zmx retry.

Open design choice to revisit during implementation: whether an `active` thread status should be skipped before `turn/start` or left to the app-server to accept/reject. The first implementation should prefer app-server rejection as the source of truth unless tests prove this creates duplicate or stuck turns.

## Test Commands

Focused tests:

```bash
swift test --filter AgentHookInstallerWrapperTests
swift test --filter CodexAppServerSessionStorageTests
swift test --filter CodexAppServerClientTests
swift test --filter CodexAppServerDeliveryTests
swift test --filter TeamInboxRequestHandlerTests
swift test --filter TeamEventLogTests
```

Regression tests from existing ownership/presence work:

```bash
swift test --filter TeamRegisterCLITests
swift test --filter TeamWatchInboxOwnershipTests
swift test --filter TeamDeliverySessionResolution
```

Full verification:

```bash
swift test
```

Known current risk: before this plan, full `swift test` reproduced unrelated `WebServerIntegrationTests` failures around WebSocket echo/reconnect. If those still fail after focused tests pass, record them separately instead of hiding them under this change.

---

### Task 1: Codex App-Server Session Storage

**Files:**
- Create: `Sources/GrafttyKit/Teams/CodexAppServerSession.swift`
- Test: `Tests/GrafttyKitTests/Teams/CodexAppServerSessionStorageTests.swift`

- [ ] **Step 1: Write failing storage round-trip test**

Add:

```swift
@Test("Codex app-server records round-trip by team/worktree/pane.")
func roundTripsCodexAppServerRecord() throws {
    let storage = CodexAppServerSessionStorage(rootDirectory: try makeTempDirectory())
    let record = CodexAppServerSessionRecord(
        teamID: "/repo",
        worktree: "/repo/.worktrees/alice",
        paneSessionName: "graftty-pane",
        socketPath: "/tmp/graftty-codex.sock",
        realBinaryPath: "/opt/homebrew/bin/codex",
        appServerPID: 1234,
        appServerProcessStartTimeMicroseconds: 5678,
        registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    try storage.write(record)

    #expect(try storage.read(
        teamID: "/repo",
        worktree: "/repo/.worktrees/alice",
        paneSessionName: "graftty-pane"
    ) == record)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter CodexAppServerSessionStorageTests
```

Expected: FAIL because `CodexAppServerSessionStorage` is undefined.

- [ ] **Step 3: Implement storage**

Create `CodexAppServerSessionRecord: Codable, Equatable, Sendable` with fields from the test.

Create `CodexAppServerSessionStorage` with:

```swift
public func write(_ record: CodexAppServerSessionRecord) throws
public func read(teamID: String, worktree: String, paneSessionName: String) throws -> CodexAppServerSessionRecord?
public func delete(teamID: String, worktree: String, paneSessionName: String) throws
public func listAll() throws -> [CodexAppServerSessionRecord]
```

Store under:

```text
<root>/<TeamInbox.fileComponent(teamID)>/codex-app-servers/<fileComponent(worktree.paneSessionName)>.json
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
swift test --filter CodexAppServerSessionStorageTests
```

Expected: PASS.

- [ ] **Step 5: Add stale cleanup tests**

Add tests proving:

- dead app-server PID deletes the record;
- mismatched recorded process start time deletes the record;
- live PID with matching process start time remains.

Use injected liveness closures so tests do not depend on real PIDs.

- [ ] **Step 6: Implement stale cleanup**

Add:

```swift
public func cleanupStale(
    isAlive: (Int32) -> Bool,
    processStartTimeMicroseconds: (Int32) -> Int64?
)
```

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Teams/CodexAppServerSession.swift Tests/GrafttyKitTests/Teams/CodexAppServerSessionStorageTests.swift
git commit -m "feat(codex): store app-server session metadata"
```

### Task 2: Wrapper Starts App-Server and Registers Metadata

**Files:**
- Modify: `Sources/GrafttyKit/Teams/AgentHookInstaller.swift`
- Modify: `Sources/GrafttyCLI/Team.swift`
- Test: `Tests/GrafttyTests/Specs/AgentHookInstallerWrapperTests.swift`
- Test: `Tests/GrafttyTests/Specs/TeamRegisterCLITests.swift`

- [ ] **Step 1: Write failing wrapper shape test**

Add to `AgentHookInstallerWrapperTests`:

```swift
@Test("Codex wrapper starts app-server, registers socket metadata, and attaches TUI over --remote.")
func codexWrapperStartsAppServerAndRemoteTUI() {
    let script = AgentHookInstaller.wrapperScript(
        runtime: .codex,
        wrapperDirectory: "/Users/x/agent-hooks/bin",
        realCommandName: "codex",
        grafttyCLIPath: "/usr/local/bin/graftty",
        codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
    )

    #expect(script.contains(#""$real_binary" app-server --listen "unix://$_graftty_codex_socket""#))
    #expect(script.contains("</dev/null"))
    #expect(script.contains("$_graftty_codex_app_server_log"))
    #expect(script.contains("_graftty_wait_for_codex_socket"))
    #expect(script.contains("team codex-app-server register"))
    #expect(script.contains("--socket \"$_graftty_codex_socket\""))
    #expect(script.contains("--app-server-pid \"$_graftty_codex_app_server_pid\""))
    #expect(script.contains(#""$real_binary" --remote "unix://$_graftty_codex_socket" "$@""#))
    #expect(script.contains("team codex-app-server unregister"))
}
```

- [ ] **Step 2: Run wrapper tests to verify failure**

Run:

```bash
swift test --filter AgentHookInstallerWrapperTests
```

Expected: FAIL because the current wrapper does not start app-server or use `--remote`.

- [ ] **Step 3: Add CLI registration command tests**

Add `TeamCodexAppServerRegister` tests that run the command with a temporary app state/team and assert a `CodexAppServerSessionRecord` is written for the canonical worktree path.

Also test `unregister` deletes the exact `(teamID, worktree, paneSessionName)` record.

- [ ] **Step 4: Implement nested CLI commands**

In `Team.configuration.subcommands`, add `TeamCodexAppServer.self`.

Add:

```swift
struct TeamCodexAppServer: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "codex-app-server",
        subcommands: [TeamCodexAppServerRegister.self, TeamCodexAppServerUnregister.self]
    )
}
```

`register` options:

```swift
@Option(name: .long) var socket: String
@Option(name: .long) var realBinary: String
@Option(name: .long) var appServerPid: Int32
```

Resolve team/worktree via `TeamPresenceCLI.resolveTeamAndWorktree()`, resolve pane session via `TeamRegisterPaneResolver`, capture app-server process start time, and write `CodexAppServerSessionRecord`.

- [ ] **Step 5: Implement Codex wrapper block**

Update the Codex runtime branch to:

```sh
graftty internal sync-codex-home
_graftty_codex_socket_dir="$TMPDIR/graftty-codex-app-server"
mkdir -p "$_graftty_codex_socket_dir"
_graftty_codex_socket="$_graftty_codex_socket_dir/$$.sock"
_graftty_codex_app_server_log="$_graftty_codex_socket_dir/$$.log"
rm -f "$_graftty_codex_socket"
env CODEX_HOME=<mirror> "$real_binary" app-server --listen "unix://$_graftty_codex_socket" </dev/null >>"$_graftty_codex_app_server_log" 2>&1 &
_graftty_codex_app_server_pid=$!
_graftty_wait_for_codex_socket() {
  _graftty_i=0
  while [ "$_graftty_i" -lt 50 ]; do
    [ -S "$_graftty_codex_socket" ] && return 0
    if ! kill -0 "$_graftty_codex_app_server_pid" 2>/dev/null; then
      return 1
    fi
    _graftty_i=$(( _graftty_i + 1 ))
    sleep 0.1
  done
  return 1
}
if ! _graftty_wait_for_codex_socket; then
  printf '%s\n' "graftty: codex app-server failed to start; see $_graftty_codex_app_server_log" >&2
  kill "$_graftty_codex_app_server_pid" 2>/dev/null || true
  wait "$_graftty_codex_app_server_pid" 2>/dev/null || true
  exit 1
fi
graftty team codex-app-server register --socket "$_graftty_codex_socket" --real-binary "$real_binary" --app-server-pid "$_graftty_codex_app_server_pid"
env CODEX_HOME=<mirror> "$real_binary" --remote "unix://$_graftty_codex_socket" "$@"
```

Cleanup must:

```sh
graftty team codex-app-server unregister
kill "$_graftty_codex_app_server_pid" 2>/dev/null || true
wait "$_graftty_codex_app_server_pid" 2>/dev/null || true
rm -f "$_graftty_codex_socket"
```

Keep the runtime TUI in the foreground. The background app-server must have stdin redirected from `/dev/null` and stdout/stderr redirected to a log file so JSON-RPC notifications or diagnostics cannot corrupt the TUI pane.

- [ ] **Step 6: Run wrapper and CLI tests**

Run:

```bash
swift test --filter AgentHookInstallerWrapperTests
swift test --filter TeamRegisterCLITests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Teams/AgentHookInstaller.swift Sources/GrafttyCLI/Team.swift Tests/GrafttyTests/Specs/AgentHookInstallerWrapperTests.swift Tests/GrafttyTests/Specs/TeamRegisterCLITests.swift
git commit -m "feat(codex): launch wrapped sessions through app-server"
```

### Task 3: App-Server JSON-RPC Client

**Files:**
- Create: `Sources/GrafttyKit/Teams/CodexAppServerClient.swift`
- Test: `Tests/GrafttyKitTests/Teams/CodexAppServerClientTests.swift`

- [ ] **Step 1: Write failing protocol tests using a fake proxy executable**

Create a temporary executable that:

- records stdin JSON lines;
- prints JSON-RPC responses for `initialize`, `thread/loaded/list`, `thread/read`, and `turn/start`;
- exits 0.

Test:

```swift
@Test("Client validates exactly one loaded thread with matching cwd and starts a turn.")
func startsTurnForLoadedThread() async throws {
    let fake = try FakeCodexProxy()
    fake.responses = [
        .loadedThreads(["thread-1"]),
        .threadRead(id: "thread-1", cwd: "/repo/.worktrees/alice", status: "idle"),
        .turnStarted(id: "turn-1"),
    ]

    let client = CodexAppServerClient(timeout: 2)
    let result = try await client.deliver(
        binaryPath: fake.executable.path,
        socketPath: "/tmp/codex.sock",
        expectedCWD: "/repo/.worktrees/alice",
        message: "hello"
    )

    #expect(result.threadID == "thread-1")
    #expect(fake.recordedRequests.contains { $0.method == "turn/start" })
}
```

Add negative tests for:

- zero loaded threads;
- more than one loaded thread;
- `thread/read.cwd` mismatch;
- `turn/start` JSON-RPC error.

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter CodexAppServerClientTests
```

Expected: FAIL because `CodexAppServerClient` is undefined.

- [ ] **Step 3: Implement client protocol and production client**

Define:

```swift
public struct CodexAppServerDeliveryResult: Sendable, Equatable {
    public let threadID: String
}

public protocol CodexAppServerClienting: Sendable {
    func deliver(
        binaryPath: String,
        socketPath: String,
        expectedCWD: String,
        message: String
    ) async throws -> CodexAppServerDeliveryResult
}
```

Production algorithm:

1. Call `request(method: "thread/loaded/list", params: ["limit": 10])`.
2. Require `result.data` to contain exactly one string thread id.
3. Call `request(method: "thread/read", params: ["threadId": id, "includeTurns": false])`.
4. Require `result.thread.cwd == expectedCWD`.
5. Call `request(method: "turn/start", params: ["threadId": id, "cwd": expectedCWD, "input": [["type": "text", "text": message]]])`.
6. Treat a JSON-RPC response with `error` as failure.

Each request opens:

```bash
<binaryPath> app-server proxy --sock <socketPath>
```

Write JSON lines:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"graftty","version":"..."}}}
{"jsonrpc":"2.0","method":"initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"thread/loaded/list","params":{"limit":10}}
```

Read stdout lines until the target response id is found or timeout expires.

- [ ] **Step 4: Run client tests**

Run:

```bash
swift test --filter CodexAppServerClientTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Teams/CodexAppServerClient.swift Tests/GrafttyKitTests/Teams/CodexAppServerClientTests.swift
git commit -m "feat(codex): add app-server JSON-RPC client"
```

### Task 4: Codex App-Server Delivery Service

**Files:**
- Create: `Sources/GrafttyKit/Teams/CodexAppServerDeliveryService.swift`
- Modify: `Sources/GrafttyKit/Teams/TeamEventLog.swift`
- Test: `Tests/GrafttyTests/Specs/CodexAppServerDeliveryTests.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamEventLogTests.swift`

- [ ] **Step 1: Write failing delivery service tests**

Cover:

- pending messages are formatted with `TeamHookRenderer.format(messages:)`;
- delivery resolves the owner presence record;
- delivery uses app-server record matching owner pane;
- worktree watermark advances only after client success;
- client failure leaves watermark unchanged;
- no owner, missing pane, missing app-server record, or stale app-server record logs a skipped attempt.

Core success test:

```swift
@Test("App-server delivery sends unread messages to the owner app-server and advances worktree watermark.")
func deliversAndAdvancesWatermark() async throws {
    let f = try Fixture()
    let id = try f.appendUnread(body: "hello")
    f.presenceRecords = [f.codexOwnerPresence(pane: "graftty-owner")]
    try f.sessionStorage.write(f.appServerRecord(pane: "graftty-owner"))

    await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree)

    #expect(f.client.calls.count == 1)
    #expect(f.client.calls[0].expectedCWD == f.worktree)
    #expect(f.client.calls[0].message.contains("hello"))
    #expect(try f.inbox.worktreeWatermark(teamID: f.teamID, worktree: f.worktree)?.lastDeliveredToAnySessionID == id)
}
```

- [ ] **Step 2: Run delivery tests to verify failure**

Run:

```bash
swift test --filter CodexAppServerDeliveryTests
```

Expected: FAIL because service is undefined.

- [ ] **Step 3: Implement event kind**

In `TeamEvent.Kind`, add:

```swift
case codexAppServerDeliveryAttempt
```

Update `TeamEventLogTests` to expect the new kind serializes.

- [ ] **Step 4: Implement delivery service**

Constructor dependencies:

```swift
public actor CodexAppServerDeliveryService {
    public init(
        inbox: TeamInbox,
        presenceRecords: @escaping @Sendable () -> [TeamPresenceRecord],
        sessionStorage: CodexAppServerSessionStorage,
        liveness: TeamDeliveryLivenessChecking,
        client: CodexAppServerClienting,
        eventLog: TeamEventLog? = TeamEventLog.defaultLog(),
        now: @escaping @Sendable () -> Date = { Date() }
    )
}
```

Method:

```swift
public func onMessageArrival(team: String, worktree: String) async
```

Algorithm:

1. Use `TeamDeliveryOwnershipResolver` with `presenceRecords` and `liveness`.
2. Resolve owner for `(team, worktree, .codex)`.
3. Require `paneSessionName`.
4. Read app-server session record for `(team, worktree, paneSessionName)`.
5. Validate app-server PID and process identity.
6. Read unread messages after `TeamInbox.worktreeWatermark`.
7. Format pending messages with `TeamHookRenderer.format(messages:)`.
8. Call client.
9. On success, write `TeamInboxWorktreeWatermark(worktree:lastDeliveredToAnySessionID:)`.
10. Log `codexAppServerDeliveryAttempt` with `outcome`, `worktree`, `runtime`, `messageIDs`, and `threadID` when available.

- [ ] **Step 5: Run delivery tests**

Run:

```bash
swift test --filter CodexAppServerDeliveryTests
swift test --filter TeamEventLogTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Teams/CodexAppServerDeliveryService.swift Sources/GrafttyKit/Teams/TeamEventLog.swift Tests/GrafttyTests/Specs/CodexAppServerDeliveryTests.swift Tests/GrafttyKitTests/Teams/TeamEventLogTests.swift
git commit -m "feat(codex): deliver team inbox through app-server"
```

### Task 5: Remove Codex Hook and zmx Nudge Delivery

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift`
- Delete or rewrite: `Sources/GrafttyKit/Teams/IdleDeliveryService.swift`
- Modify: `Sources/GrafttyKit/Teams/TeamHookRenderer.swift`
- Modify: `Tests/GrafttyKitTests/Teams/TeamInboxRequestHandlerTests.swift`
- Delete or rewrite: `Tests/GrafttyTests/Specs/IdleDeliveryTests.swift`
- Delete or rewrite: `Tests/GrafttyKitTests/Teams/IdleDeliveryEndToEndTests.swift`
- Delete: `Tests/GrafttyKitTests/Teams/ZmxNudgeSenderTests.swift`
- Delete or rewrite: `Tests/GrafttyKitTests/Teams/TeamInboxZmxWatermarkTests.swift`

- [ ] **Step 1: Write failing request handler tests**

Update tests to assert:

- Codex `stop` returns `{}` and does not call an `onStop` delivery callback.
- Codex `post-tool-use` does not render or advance urgent messages.
- Claude hook behavior remains unchanged.

- [ ] **Step 2: Run request handler tests**

Run:

```bash
swift test --filter TeamInboxRequestHandlerTests
```

Expected: FAIL while old Codex hook behavior is present.

- [ ] **Step 3: Remove Codex delivery callbacks from request handler**

Remove `onStop` from `TeamInboxRequestHandler` if no longer needed. If Claude still needs a callback, rename it so Codex behavior cannot call it accidentally.

For Codex:

- `session-start` may still render initial team context if desired;
- `post-tool-use` should not consume team inbox messages;
- `stop` should not deliver messages.

- [ ] **Step 4: Remove zmx nudge service**

Delete `ZmxNudgeSender` and `NudgeSender`.

Delete `IdleDeliveryService` entirely if no code imports it after `GrafttyApp` is rewired. If `TeamInbox.zmxWatermark` APIs remain for migration/back-compat, keep them isolated in `TeamInbox` and rename tests to prove they are legacy storage only, not delivery behavior.

- [ ] **Step 5: Update tests**

Remove tests whose only purpose is zmx delivery:

```bash
git rm Tests/GrafttyKitTests/Teams/ZmxNudgeSenderTests.swift
git rm Tests/GrafttyKitTests/Teams/IdleDeliveryEndToEndTests.swift
git rm Tests/GrafttyTests/Specs/IdleDeliveryTests.swift
```

If `TeamInbox.zmxWatermark` APIs are removed:

```bash
git rm Tests/GrafttyKitTests/Teams/TeamInboxZmxWatermarkTests.swift
```

- [ ] **Step 6: Run focused tests**

Run:

```bash
swift test --filter TeamInboxRequestHandlerTests
swift test --filter CodexAppServerDeliveryTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift Sources/GrafttyKit/Teams/TeamHookRenderer.swift
git add -u Sources/GrafttyKit/Teams Tests/GrafttyKitTests/Teams Tests/GrafttyTests/Specs
git commit -m "refactor(codex): remove zmx nudge delivery"
```

### Task 6: Wire App Startup to App-Server Delivery

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Test: `Tests/GrafttyTests/Specs/CodexAppServerDeliveryTests.swift`
- Test: `Tests/GrafttyTests/Specs/TeamWatchInboxOwnershipTests.swift`

- [ ] **Step 1: Add app wiring tests where practical**

If existing app startup seams are hard to instantiate, prefer small pure helpers on `GrafttyApp` and test those:

- grouping appended inbox messages by recipient worktree;
- calling Codex delivery only for worktrees with Codex owner records;
- not invoking delivery from hook callbacks.

- [ ] **Step 2: Remove idle delivery fields from `AppServices`**

Remove:

```swift
var idleDeliveryService: IdleDeliveryService?
var agentStateRegistry: WorktreeAgentStateRegistry?
var inputActivityRegistry: PaneInputActivityRegistry?
var graceScheduler: EngagedGraceScheduler?
```

Keep `inboxObserverCancellables` and `inboxObservers`.

- [ ] **Step 3: Replace startup delivery construction**

Remove construction of:

```swift
IdleDeliveryService(...)
PaneInputActivityRegistry
WorktreeAgentStateRegistry
EngagedGraceScheduler
ZmxNudgeSender
```

Add:

```swift
let codexDeliveryService = CodexAppServerDeliveryService(
    inbox: services.teamInbox,
    presenceRecords: { presenceIndex.allRecords() },
    sessionStorage: CodexAppServerSessionStorage(rootDirectory: TeamPresenceStorage.defaultRoot()),
    liveness: AppTeamDeliveryLiveness(...),
    client: CodexAppServerClient()
)
```

Retain it on `AppServices`.

- [ ] **Step 4: Rewire `TeamInboxObserver` append handling**

On appended messages:

```swift
for worktree in recipientWorktrees {
    Task {
        await codexDeliveryService.onMessageArrival(team: teamID, worktree: worktree)
    }
}
```

Do not pass zmx session names.

- [ ] **Step 5: Remove Codex lifecycle hook state updates**

Remove `CodexStopDeliveryPlan`, `shouldUpdateDeliveryStateForHook`, and hook callbacks that only existed to drive idle delivery. Keep hook output route itself for initial context/back-compat if still used.

- [ ] **Step 6: Run app-level focused tests**

Run:

```bash
swift test --filter CodexAppServerDeliveryTests
swift test --filter TeamWatchInboxOwnershipTests
swift test --filter TeamDeliverySessionResolution
```

Expected: PASS or delete/replace obsolete `TeamDeliverySessionResolution` tests if that type becomes unused.

- [ ] **Step 7: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift Tests/GrafttyTests/Specs/CodexAppServerDeliveryTests.swift
git add -u Tests/GrafttyTests/Specs
git commit -m "feat(app): wire Codex inbox delivery to app-server"
```

### Task 7: Documentation and Specs Cleanup

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-06-18-delivery-ownership-design.md`
- Modify: `docs/superpowers/plans/2026-06-18-delivery-ownership.md` only if adding an implementation note is useful.
- Search/update any generated specs if this repo requires regeneration.

- [ ] **Step 1: Search stale zmx delivery wording**

Run:

```bash
rg -n "zmx.*delivery|zmx.*nudge|IdleDeliveryService|post-tool-use|post tool|Stop.*delivery|app-server delivery remains disabled|app-server transport disabled" README.md docs Sources Tests
```

- [ ] **Step 2: Update docs**

README should say:

- Codex wrappers start a Codex app-server and attach the TUI through `--remote`.
- Team/CI messages are delivered as Codex app-server turns.
- zmx is not used for Codex inbox delivery.

The June 18 ownership docs should be updated with a short note that this plan supersedes the deferred transport section.

- [ ] **Step 3: Run doc search again**

Run:

```bash
rg -n "zmx.*delivery|zmx.*nudge|IdleDeliveryService|app-server delivery remains disabled|app-server transport disabled" README.md docs Sources Tests
```

Expected: only historical plan text or explicitly marked superseded notes remain.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/superpowers/specs/2026-06-18-delivery-ownership-design.md docs/superpowers/plans/2026-07-05-codex-app-server-delivery.md
git commit -m "docs(codex): plan app-server team inbox delivery"
```

### Task 8: Verification and Merge Readiness

**Files:**
- No new files unless fixing test fallout.

- [ ] **Step 1: Run focused suite**

Run:

```bash
swift test --filter AgentHookInstallerWrapperTests
swift test --filter CodexAppServerSessionStorageTests
swift test --filter CodexAppServerClientTests
swift test --filter CodexAppServerDeliveryTests
swift test --filter TeamInboxRequestHandlerTests
swift test --filter TeamEventLogTests
swift test --filter TeamRegisterCLITests
swift test --filter TeamWatchInboxOwnershipTests
```

Expected: PASS.

- [ ] **Step 2: Run full suite**

Run:

```bash
swift test
```

Expected: PASS, except any pre-existing WebServer integration failures must be reproduced and documented with exact test names.

- [ ] **Step 3: Manual smoke test**

Install/run the app, then:

1. Open a Codex pane through Graftty.
2. Confirm process list shows `codex app-server --listen unix://...`.
3. Confirm the wrapped Codex TUI command contains `--remote unix://...`.
4. Run `graftty team send <codex-member> "hello from smoke"`.
5. Confirm the message appears in Codex as an app-server turn, not as typed terminal input.
6. Confirm the worktree watermark advances and no zmx nudge event is logged.

- [ ] **Step 4: Inspect for removed zmx path**

Run:

```bash
rg -n "ZmxNudgeSender|IdleDeliveryService|NudgeSender|zmxNudgeAttempt|advanceZmxWatermark|zmxWatermark" Sources Tests
```

Expected: no production delivery path remains. Any remaining `zmxWatermark` references must be legacy storage only and documented as such.

- [ ] **Step 5: Final commit if needed**

```bash
git status --short
git add <remaining files>
git commit -m "test(codex): verify app-server delivery path"
```

## Review Checklist

- Does the wrapper kill its app-server on normal TUI exit?
- Does stale app-server metadata get cleaned after wrapper crashes?
- Does delivery refuse to guess when `thread/loaded/list` returns zero or multiple loaded threads?
- Does delivery validate exact `cwd` before `turn/start`?
- Does delivery leave messages unread on every validation/client failure?
- Is all Codex delivery independent of urgent vs normal priority?
- Are `post-tool-use` and `stop` free of Codex message delivery behavior?
- Is there no zmx fallback after app-server validation fails?
- Can Claude still receive existing hook/watch-inbox deliveries?
