# W2 — Shared Terminal Core + Ownership Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One host-side terminal-attach core serves both `/ws` and SSH: the zmx-attach engines unify on the PTY-backed implementation, the ownership coordinator becomes transport-neutral, and SSH terminal clients gain the full display-ownership protocol (hello / take-control / owner-resize / snapshots) that `/ws` clients have today. `/ws` behavior is unchanged throughout — its tests are the regression harness.

**Architecture:** `WebSocketBridgeCoordinator` (already transport-injected via `sendText`/`resize`/`write` seams) is renamed and moved as the shared `TerminalAttachCoordinator`. `WebSession`'s PTY engine is extracted as `ZmxAttachEngine: TerminalByteStream` and replaces `ZmxAttachStream` on the SSH path (fixing SSH resize, which today no-ops with ENOTTY on a pipe). Ownership envelopes over SSH ride the same `WebControlEnvelope` JSON, carried on the session channel via SSH extended data with length-prefixed framing — validated by a decision-gate spike (Task 1) with a named fallback.

**Tech Stack:** swift-nio-ssh 0.13 (`SSHChannelData` `.channel`/`.stdErr` data types), existing `LengthPrefixedFraming`, `WebControlEnvelope`, `SessionDisplayOwnershipStore`, Swift Testing.

## Global Constraints

- `/ws` behavior unchanged: `Tests/GrafttyKitTests/Web/WebSocketBridgeOwnershipTests.swift`, `WebServerIntegrationTests.swift` (two known PTY-echo flakes: `wsEchoRoundTrip`, WEB-5.6), `WebSessionTests.swift`, and the `OwnershipModelTests` target (`swift test --filter OwnershipModel`) must pass throughout — mechanical rename edits only.
- iOS CI green required before merge for every task touching `GrafttyMobileKit`; run SSH loopback suites (`SSHTerminalLoopbackTests`, `SSHAuthLoopbackTests`, `SSHPanesAndControlLoopbackTests`) on the simulator for host-agent changes too (they exercise the server side in-process).
- New iOS test FILES require manual pbxproj registration (known trap: "0 tests ran") — prefer extending existing files.
- `scripts/generate-specs.py` + commit `SPECS.md` alongside spec changes; no literal escaped quotes in `@spec` titles; new spec IDs for this milestone: `REMOTE-9.1`–`REMOTE-9.4` (verify unused first).
- Strict concurrency, warnings-as-errors. Lock-discipline invariants are load-bearing: `SessionDisplayOwnershipStore` notifies observers OUTSIDE its lock; `RemoteAttachmentRegistry.onLastDetach` fires outside its lock. Preserve exactly.
- RED/GREEN TDD; commit per green task; `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Run `/code-review xhigh --fix` after opening the PR (user instruction; overrides CLAUDE.md's "before").

## Key facts (from the survey — brief-writers copy freely)

- The reusable ownership core already exists: `WebSocketBridgeCoordinator`, `Sources/GrafttyKit/Web/WebServer.swift:97-361` (`@unchecked Sendable`, NSLock; seams `sendText`/`resize`/`write`; handles `.hello`→`attachClient`, `.takeControl`→`claimOwner`, `.ownerResize`/legacy `.resize`→`ownerResize`, owner-gated `handleBinary`, `handlePTYSize`→`.grid`+snapshot, `detach()`; snapshot localization at 335-354; `bindOrVerify` at 293-302). Ownership fan-out: `WebDisplayOwnershipBroadcaster` (same file, 8-95).
- `@testable` consumers that break on rename: `WebSocketBridgeOwnershipTests.swift` (GrafttyKitTests) and `Tests/OwnershipModelTests/MultiTransportWorld.swift` + its runners.
- `WebSession` (`Sources/GrafttyKit/Web/WebSession.swift`): PTY-backed zmx attach — `PtyProcess.spawn` via `ZmxLauncher` (:120), real `resize` ioctl (:150), 250ms winsize poller (:244), reader thread (:206), `onPTYData`/`onExit`/`onPTYSize` callbacks, `inputState: ZmxInputState?`, `attachmentRegistry` accounting (:132), shell-integration env via `ZmxSpawnConfiguration`.
- `ZmxAttachStream` (`Sources/Graftty/Remote/ZmxAttachStream.swift`): Process+Pipe `TerminalByteStream` conformer; `resize` is an ENOTTY no-op (:111-120) — SSH `window-change` currently does nothing end-to-end; header says "R6 consolidates" (:14-15). Constructed only in `GrafttyApp.swift:396-402` inside `WebRTCHostAgent(streamFactory:)`.
- `TerminalSessionHandler` (`Sources/GrafttyHostAgent/SSH/Channels/TerminalSessionHandler.swift`): env `GRAFTTY_SESSION` (:61-70), accepts `pty-req` without capturing size (:71-79), `shell`→`factory(name)` (:80-89), `window-change`→`stream.resize` (:91-97), inbound bytes→`stream.send` (:42-57), `stream.inboundBytes`→outbound (:157-168). NO ownership, NO client kind, NO initial-size capture.
- Mobile: `SessionClient` (`@MainActor`) already speaks the whole ownership protocol over `WebSocketClient` `.text` frames (`handleTextFrame` :727-766, `isOwner` :142-149, `OwnershipTransportMode` :172-176 keyed off `supportsWebControlTextFrames`); `TerminalSessionClient` inherits `supportsWebControlTextFrames=false` → `.legacy` always-owner mode, treats `.text` as raw bytes (:104-106), `resize`→SSH `window-change` (:148-158). Default no-op `sendHello`/`takeControl`/`ownerResize` live in `WebSocketClient.swift:33-46`.
- `SubsystemDispatcher` (`Sources/GrafttyHostAgent/SSH/Channels/SubsystemDispatcher.swift`) installs `TerminalSessionHandler` on env/pty-req/shell events; custom subsystems use `LengthPrefixedFraming` — reuse that framing type for the extended-data carrier.
- The authenticated peer identity (from `SSHUserAuthDelegate`) is resolved at userauth; the SSH terminal's `DisplayClientID` should derive from it (`ssh-<RemoteDeviceID>-<channel>`), unlike `/ws`'s random UUID.
- `GrafttyApp.swift:391-395` comment marks exactly this gap ("Until Task 4+ adds explicit display-owner protocol handling…"). `WebRTCHostAgent` init (`Sources/GrafttyHostAgent/WebRTCHostAgent.swift:57-75`) is where new ownership deps thread through to `SubsystemDispatcher` (:250-262).

---

### Task 1: Decision gate — SSH extended-data carrier spike

**Files:**
- Test: `Tests/GrafttyMobileKitTests/Remote/SSH/SSHExtendedDataCarrierTests.swift` — NO: new iOS files need pbxproj edits; instead extend `Tests/GrafttyMobileKitTests/Remote/SSH/SSHTerminalLoopbackTests.swift` with the spike test (delete or promote it in Task 4/5).

**The question:** can swift-nio-ssh 0.13 carry data BOTH directions on a session channel's `.stdErr` extended-data stream while `.channel` data flows normally? (RFC 4254 permits it; NIOSSH's client-side write support for extended data is the unknown.)

- [ ] **Step 1:** In the existing SSH loopback harness, open a session channel, exchange: server→client `.stdErr` writes and client→server `.stdErr` writes interleaved with `.channel` byte traffic; assert both sides receive extended-data intact, in order, and that `.channel` bytes are unaffected.
- [ ] **Step 2:** Run on the iOS simulator. PASS ⇒ the carrier is `.stdErr` + `LengthPrefixedFraming`-wrapped `WebControlEnvelope` JSON; record the decision in the ledger and proceed. FAIL ⇒ **fallback**: a `terminal-control@graftty.dev` subsystem channel per terminal session (same `LengthPrefixedFraming` + envelope JSON), correlated to its session channel by `sessionName` through a per-connection rendezvous map; update Tasks 4/5 briefs accordingly before dispatching them and note the fallback in the plan doc.
- [ ] **Step 3:** Commit the spike test (kept as a pinned protocol-capability test) `test(remote): pin bidirectional SSH extended-data carrier (W2 decision gate)`.

### Task 2: Rename/move the coordinator — `TerminalAttachCoordinator`

**Files:**
- Create: `Sources/GrafttyKit/Remote/TerminalAttachCoordinator.swift` (moved `WebSocketBridgeCoordinator` + `WebDisplayOwnershipBroadcaster` → `DisplayOwnershipBroadcaster`)
- Modify: `Sources/GrafttyKit/Web/WebServer.swift` (delete moved types; `WebSocketBridgeHandler` consumes the renamed types)
- Modify: `Tests/GrafttyKitTests/Web/WebSocketBridgeOwnershipTests.swift`, `Tests/OwnershipModelTests/MultiTransportWorld.swift` (+ any runner references) — mechanical rename only
- Test: no new tests — this task is green when ALL existing suites pass unchanged (including `swift test --filter OwnershipModel`)

**Interfaces:**
- Produces: `internal final class TerminalAttachCoordinator` — identical API to today's coordinator (init seams `sendText:resize:write:`, `handleControl`, `handleBinary`, `handlePTYSize`, `detach`, `handleLegacyResize`), same file-internal helpers. `DisplayOwnershipBroadcaster` identical to `WebDisplayOwnershipBroadcaster`.
- Rule: NO behavior change, NO signature change beyond the names. Any improvement urge goes to Task 4.

Steps: move → rename → fix references → full `swift test` + `swift test --filter OwnershipModel` → commit `refactor(remote): extract TerminalAttachCoordinator from the /ws bridge (no behavior change)`.

### Task 3: Unify the attach engines — `ZmxAttachEngine`

**Files:**
- Create: `Sources/GrafttyKit/Remote/ZmxAttachEngine.swift` — the PTY engine extracted from `WebSession`, conforming to `TerminalByteStream` (async `send`/`resize`/`close` + `inboundBytes: AsyncStream<Data>`) while keeping the callback surface (`onExit`, `onPTYSize`) and injectables (`inputState`, `attachmentRegistry`, `processEnvForTesting`)
- Modify: `Sources/GrafttyKit/Web/WebSession.swift` → thin adapter over the engine (public API and `WebSessionTests` behavior unchanged), or delete `WebSession` and point the bridge handler at the engine directly IF `WebSessionTests` can be retargeted mechanically — decide by which keeps the diff smaller; state the choice in the report
- Modify: `Sources/Graftty/GrafttyApp.swift:396-402` — `streamFactory` constructs `ZmxAttachEngine` (drop the stale "registry is accounting only" comment)
- Delete: `Sources/Graftty/Remote/ZmxAttachStream.swift` + `Tests/GrafttyTests/Remote/ZmxAttachStreamRegistryTests.swift` (port its registry-balance assertions — TERM-11.5 — onto engine tests)
- Test: engine unit tests in `Tests/GrafttyKitTests/Remote/ZmxAttachEngineTests.swift` (spawn/echo/resize-ioctl-reaches-real-PTY/close/registry attach-detach balance incl. instant-death race)

**Interfaces:**
- Consumes: `ZmxLauncher`/`PtyProcess` (as `WebSession` does today), `TerminalByteStream` (`Sources/GrafttyKit` — read its exact protocol first).
- Produces: `public final class ZmxAttachEngine: TerminalByteStream` with `init(config: WebSession.Config`-equivalent`)`, plus `onExit`/`onPTYSize` setters — consumed by Task 4's server wiring and by `WebSession`/bridge.
- Behavioral upgrade this task delivers to SSH: real `resize` (ioctl on PTY master) replacing the ENOTTY no-op — add an engine test proving `resize` actually changes the PTY winsize (read it back with TIOCGWINSZ).

RED first for engine tests; `/ws` suites + full suite green; iOS SSH loopback suites green (they consume `streamFactory` targets in-process). Commit `feat(remote): ZmxAttachEngine — one PTY-backed zmx attach engine for /ws and SSH`.

### Task 4: Server-side ownership on the SSH terminal path

**Files:**
- Modify: `Sources/GrafttyHostAgent/SSH/Channels/TerminalSessionHandler.swift` — drive a `TerminalAttachCoordinator` (per Task 1's carrier): decode inbound extended-data frames → `handleControl`; owner-gate inbound `.channel` bytes through `handleBinary`; `handlePTYSize` wired from the engine's `onPTYSize`; send coordinator `sendText` output as extended-data frames; `detach()` on `channelInactive`; capture `pty-req` cols/rows as the initial grid for `.hello` fallback
- Modify: `Sources/GrafttyHostAgent/SSH/Channels/SubsystemDispatcher.swift` + `Sources/GrafttyHostAgent/WebRTCHostAgent.swift` + `Sources/Graftty/GrafttyApp.swift` — thread `SessionDisplayOwnershipStore` + `DisplayOwnershipBroadcaster` + the authenticated peer's `RemoteDeviceID` through to the handler; `DisplayClientID` = `ssh-<deviceID>-<uuid>`; `DisplayClientKind` = `.ios`
- Test: extend `Tests/GrafttyTests/Remote/SSH/TerminalSessionHandlerTests.swift` — spec tests below

**Spec texts (EARS, verbatim as test titles; verify IDs are free first):**
- `@spec REMOTE-9.1: When an SSH terminal session attaches, the host shall register the client in the display-ownership store with kind ios and the authenticated device identity.`
- `@spec REMOTE-9.2: While an SSH terminal client is not the display owner, the host shall discard its terminal input bytes and rebroadcast the current ownership snapshot.`
- `@spec REMOTE-9.3: When an SSH terminal client issues a take-control request, the host shall apply the same owner-eligibility rules as the web transport.`
- `@spec REMOTE-9.4: When the PTY size changes, the host shall push grid and ownership envelopes to SSH terminal clients over the control carrier.`

RED/GREEN per spec; `/ws` + OwnershipModel suites stay green; iOS loopback suites green. Commit `feat(remote): display ownership on SSH terminals (REMOTE-9.1..9.4)`.

### Task 5: Mobile — `TerminalSessionClient` speaks the ownership protocol

**Files:**
- Modify: `Sources/GrafttyMobileKit/Remote/SSH/Channels/TerminalSessionClient.swift` — `supportsWebControlTextFrames = true`; implement `sendHello`/`takeControl`/`ownerResize` (encode `WebControlEnvelope`, frame, write via the Task-1 carrier); surface inbound control frames as `WebSocketFrame.text(String)` so `SessionClient.handleTextFrame` works unmodified; `.channel` bytes remain `.binary`
- Modify (only if needed): `Sources/GrafttyMobileKit/Session/SessionClient.swift` — expectation: zero changes; if something IS needed, stop and report NEEDS_CONTEXT rather than reshaping SessionClient
- Test: extend `Tests/GrafttyMobileKitTests/Remote/SSH/SSHTerminalLoopbackTests.swift` — two SSH clients on one session: first hello owns, second hello follows; follower bytes discarded server-side; takeControl flips ownership (epoch bump observed); ownerResize accepted only from owner; snapshot localization correct on both

RED/GREEN on the simulator; full iOS suite; mac build green. Commit `feat(mobile): SSH terminal ownership — hello/take-control/owner-resize over the SSH carrier`.

### Task 6: End-to-end parity test + SPECS.md + comment sweep

**Files:**
- Test: extend the iOS loopback with one mixed-transport scenario if feasible in-process (an SSH client and a coordinator-driven fake web client sharing one store) — else document why not in the report
- Modify: stale comments — `GrafttyApp.swift:391-395` (gap now closed), `RemoteAttachmentRegistry.swift` doc (both paths now one engine), `WebControlEnvelope.swift` doc (now shared by two transports)
- Regenerate `SPECS.md`; full mac suite + full iOS suite + OwnershipModel filter

Commit `test(remote): SSH/ws ownership parity end-to-end + spec regen`.

---

## Self-review notes

- Task 2 before Task 3/4 so every later diff is against the renamed core; Tasks 4/5 depend on Task 1's carrier decision — do not dispatch them before the gate resolves.
- The model checker (`OwnershipModelTests/MultiTransportWorld`) drives the real coordinator — it is the strongest safety net for Task 2 and the owner-gate semantics in Task 4. Extending it with SSH-transport clients is deliberately OUT of scope (follow-up), since Task 4 reuses the exact coordinator it already checks.
- `declaredDisplayClientKind` stays `/ws`-only (SSH kind comes from the authenticated channel, not headers).
- Out of scope: signaling wiring (W3), revocation (W4), `/ws` retirement or REMOTE-5.1 (W5), Bonjour, multi-connection host agent.

## Risks

1. **Task 1 gate fails** → fallback channel design adds a rendezvous map; Tasks 4/5 briefs must be rewritten before dispatch. Bounded: the fallback reuses the R5 subsystem pattern wholesale.
2. **WebSession extraction regressions** — mitigated by keeping `WebSessionTests` + the two known flakes as the harness and preserving thread structure (reader/poller Threads) inside the engine.
3. **Coordinator rename breaks the model checker silently** (compile-time only — it's `@testable`): run the OwnershipModel filter explicitly in Tasks 2/4/5, not just the default suite.
4. **iPad regression**: iPad terminals currently run `.legacy` always-owner over SSH; Task 5 flips them into real ownership arbitration alongside Mac/web clients — verify take-control UX on iPad in the PR test plan (real device/simulator smoke).
