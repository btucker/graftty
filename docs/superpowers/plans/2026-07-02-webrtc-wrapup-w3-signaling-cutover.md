# W3 — Mobile Signaling Wiring + Native SSH Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Paired iPhones and iPads negotiate a `RemoteHostConnection` (WebRTC → SSH) in production and prefer it for terminal + pane traffic, with `/ws` as the explicit, observable fallback. This is the milestone that puts real traffic on everything R1–R5, W1, and W2 built.

**Architecture:** A new `RemoteConnectionCoordinator` (MainActor, owned by `RootView`, shared by both size classes) owns the negotiate-on-demand flow: paired `Host` → factory builds `RemoteHostConnection` from the pairing artifacts → `createOffer` → `SignalingClient.exchange` (POST `/v1/rtc/offer`) → `applyAnswer` (which completes SSH userauth) → registry. `RemoteHostConnection` gains drop-event observability (today its ICE-state delegate is an empty no-op) so the coordinator evicts dead connections and `SessionClient`'s existing backoff loop transparently re-negotiates via the factory closure. The iPad-only `IPadAppState` registry is superseded by the shared coordinator.

**Tech Stack:** existing `SignalingClient` (injectable `Transport`), `RemoteHostConnection` actor, stasel/WebRTC, `SessionClient` backoff loop (IOS-7.4), Swift Testing.

## Global Constraints

- iOS CI green before merge; iOS simulator suites are the RED/GREEN loop for all UIKit-gated work. New iOS test FILES need manual pbxproj registration — extend existing files.
- `scripts/generate-specs.py` + commit `SPECS.md` with any spec change; EARS phrasing per CLAUDE.md; no literal escaped quotes in titles.
- REMOTE-2.1 stays in the disabled inventory this milestone (promotion is W4); W3 writes the behavioral reconnect test WITHOUT the `@spec` ID (W4 attaches the ID when promoting — avoid duplicate-ID failures).
- `GrafttyHostAgent`/`GrafttyKit` are not importable from iOS tests (AppKit split) — mobile E2E tests mirror the host side per the established loopback pattern.
- Fallback to `/ws` must be observable (promote the existing `remoteWiringLogger` nil-fallback log to `.warning` per its own comment) but UI stays subtle — no saturated status decorations (recorded user preference).
- Strict concurrency, warnings-as-errors; RED/GREEN TDD; commit per green task with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; `/code-review xhigh --fix` after opening the PR.

## Key facts (survey-verified @ 326ca43 — brief-writers copy freely)

- Registry today: `IPadAppState.remoteHostConnectionsByHostId` (`Sources/GrafttyMobileKit/App/IPadAppState.swift:111`), `setRemoteHostConnection` (:127) has ZERO callers; `RootView.swift:12` owns `IPadAppState` above the size-class fork (:19-26); compact path passes NO app state (`RootView.swift:93,257`).
- `SignalingClient.exchange(baseURL:offer:) async throws -> SignalingAnswer` (`Sources/GrafttyMobileKit/Remote/SignalingClient.swift:31`), injectable `Transport` (:11), errors `.http/.decode/.transport` (:19). Wire types `SignalingOffer{clientDeviceID, sdp}` / `SignalingAnswer{sdp}` (`Sources/GrafttyProtocol/SignalingEnvelope.swift`).
- `RemoteHostConnection(clientKey:expectedHostFingerprint:)` (`:97`); `createOffer()` (:122, client creates the data channel, non-trickle SDP carries candidates); `applyAnswer(_:)` (:213, returns only after SSH userauth → `.connected`); `openTerminalSession` (:278) throws `.notConnected` when dead; `close()` (:363). ICE-state delegate is a NO-OP (`:549`) — no drop event reaches the app.
- Pairing artifacts: `Host.remoteDeviceID` (`Hosts/Host.swift:17`); `PinnedHostStore.get(id:)` → `.fingerprint` (`Remote/PinnedHostStore.swift:140,34`); `ClientIdentityStore.loadOrGenerateAndPersist()` (`:63`); `ClientDeviceIDStore` (used at `PairDeviceFlowView.swift:354`); construction-from-one-directory pattern at `PairDeviceFlowView.buildModel` (:346-370).
- Session fork already exists: `SessionClient.live(baseURL:sessionName:role:remoteHost:)` (`App/SessionLifecycleEnvironment.swift:46-64`); `buildPaneEnvironment(remoteHost:)` (:111) has NO production caller; `RootView.openWebSocket()` (:439-469, fallback log at :451); preview pool `WorktreeDetailView.swift:90` never passes `remoteHost` (even on iPad).
- Reconnect: `SessionClient` backoff re-invokes the ws factory (`Session/SessionClient.swift:322-388`, schedule :60/236, `forceReconnectNow` :592); scenePhase teardown/rehydrate drives `openWebSocket` via `.task(id: dialKey)` (`RootView.swift:369-423`). A dead `RemoteHostConnection` today → `.notConnected` forever-loop (no re-negotiation path).
- Host side is live and needs ONE change: `GrafttyApp.swift:1620-1629`'s signaling closure maps ALL errors (including `WebRTCHostAgent.HostError.busy`, thrown at `WebRTCHostAgent.swift:115-117`) to `.internalFailure` → HTTP 500. `WebServer.SignalingHandlerOutcome.unavailable` → 503 exists (`Web/WebServer.swift:146-151,855-906`).
- Related spec IDs: REMOTE-2.1 disabled inventory (`Tests/GrafttyTests/Specs/RemoteTodo.swift:12`); IPAD-5.1/5.2 (background teardown / foreground rebuild-from-signaling) in SPECS.md :1545-1554 — check whether they live in `IpadTodo.swift` as disabled inventory; if so W3 Task 4 promotes IPAD-5.2 (and 5.1 if the teardown assertion is cheap); their EARS text mentions "Noise handshake" which is superseded — update wording to "SSH userauth" via the changing-behavior flow when promoting.

---

### Task 1: Drop-event observability on `RemoteHostConnection`

**Files:**
- Modify: `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift`
- Test: extend `Tests/GrafttyMobileKitTests/Remote/SSH/SSHTerminalLoopbackTests.swift` (or the most fitting existing SSH loopback file — new files need pbxproj edits)

**Interfaces:**
- Produces: `public var onStateChange: (@Sendable (State) -> Void)?` (or an equivalent single observer set before `createOffer`) fired on EVERY transition into `.failed`, `.closed`, and `.connected`; plus ICE-state handling: `PeerConnectionDelegate.didChange RTCIceConnectionState` (:549) maps `.failed` → connection `state = .failed(reason:)` + teardown, `.disconnected` → grace (WebRTC can recover `.disconnected`; only `.failed` is terminal — document the choice). The data-channel close path must fire it too.
- Consumed by Task 2's coordinator (eviction) and Task 4 (reconnect).

Steps: RED loopback test — negotiate a loopback pair, kill the underlying peer/data channel, assert the observer fires with a terminal state exactly once (no double-fire from ICE+DC both closing); GREEN implement; idempotent-close regression test. Commit `feat(remote): RemoteHostConnection surfaces terminal state transitions`.

### Task 2: `RemoteConnectionCoordinator` — factory + registry + negotiate-on-demand

**Files:**
- Create: `Sources/GrafttyMobileKit/Remote/RemoteConnectionCoordinator.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift` (:1620-1629) — map `HostError.busy` → `.unavailable` (503) in the signaling closure (host-side one-liner + host test in `Tests/GrafttyTests/`)
- Modify: `Sources/GrafttyMobileKit/App/IPadAppState.swift` — registry members deprecated/removed in favor of the coordinator (keep `selectedHostId`/`sidebarWidth` UI state; migrate `remoteHostConnection(for:)` callers)
- Test: extend an existing GrafttyMobileKitTests file near the Remote/ tests

**Interfaces (produces):**
```swift
@MainActor
public final class RemoteConnectionCoordinator: ObservableObject {
    public init(
        directory: URL = ClientIdentityStore.defaultDirectory,
        signaling: SignalingClient = SignalingClient(),
        connectionFactory: ((Curve25519.Signing.PrivateKey, RemoteIdentityFingerprint) -> RemoteHostConnection)? = nil  // test seam
    )
    /// Returns a live connection for a PAIRED host, negotiating at most one
    /// per host at a time (in-flight dedup). Returns nil fast when the host
    /// is unpaired (remoteDeviceID nil / no pinned entry) or negotiation
    /// fails — callers fall back to /ws. Evicts on drop events (Task 1).
    public func connection(for host: Host) async -> RemoteHostConnection?
    public func invalidate(host: Host) async   // eviction + close, used by reconnect/foreground paths
}
```
- Negotiation body: artifacts from the one-directory stores (mirror `PairDeviceFlowView.buildModel`) → `RemoteHostConnection(clientKey:expectedHostFingerprint:)` → set `onStateChange` (terminal → evict from registry) → `createOffer()` → `signaling.exchange(baseURL: host.baseURL, offer: SignalingOffer(clientDeviceID:sdp:))` → `applyAnswer(RTCSessionDescription(type: .answer, sdp:))` → register. A 503/busy signaling response yields nil (fallback) WITHOUT marking the host permanently bad; log at `.warning` via a coordinator logger.
- Tests (stub `SignalingClient.Transport` + `connectionFactory` seam): unpaired-host fast-nil; in-flight dedup (two concurrent calls, one negotiation); busy-503 → nil + retryable; eviction on state-change; invalidate closes.

Commit `feat(remote): RemoteConnectionCoordinator — production signaling negotiation + registry (host busy → 503)`.

### Task 3: UI wiring — both size classes prefer SSH; pane environment goes live

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift` — RootView owns one `RemoteConnectionCoordinator`; BOTH the compact `SingleSessionView` (:93) and `IPadRootLayout` receive it; `openWebSocket()` awaits `coordinator.connection(for: step.host)` (it's already async-friendly via the `.task` driver); nil-fallback log promoted to `.warning` (comment at :451 says to do exactly this once the cache populates)
- Modify: `Sources/GrafttyMobileKit/App/IPadRootLayout.swift` (:282-287) and `Sources/GrafttyMobileKit/UI/WorktreeDetailView.swift` (:90) — preview pool consults the coordinator too (iPad previews currently NEVER ride SSH — survey gap)
- Modify: `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift` — `buildPaneEnvironment` gets its first production caller: construct the `PaneEnvironment` where the pane UI needs it on both paths (find the natural owner — likely alongside the coordinator wiring; keep minimal, the env plumbing already exists)
- Test: iOS tests for the decision logic (paired→SSH, unpaired→/ws, mid-session eviction→next dial falls back); UI-level wiring verified via the loopback E2E in Task 5

Commit `feat(mobile): both size classes negotiate SSH for paired hosts; /ws fallback observable`.

### Task 4: Reconnect — factory-level re-negotiation + foreground rebuild

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift` — `SessionClient.live`'s factory closure captures the COORDINATOR + host (not a fixed connection): each (re)dial asks `coordinator.connection(for:)`, so after a drop the backoff loop transparently re-negotiates (fresh WebRTC + fresh SSH userauth — REMOTE-2.1's substance)
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift` — scenePhase background path calls `coordinator.invalidate(host:)` per IPAD-5.1 (teardown), foreground rebuild rides the existing `verifyThenOpen()` re-dial (IPAD-5.2's rebuild-from-signaling)
- Specs: if IPAD-5.1/5.2 are disabled inventory in `IpadTodo.swift`, promote IPAD-5.2 (and 5.1 if cheap) with EARS text updated from "Noise handshake" to SSH userauth wording per the changing-behavior flow; regenerate SPECS.md. REMOTE-2.1's behavioral test is WRITTEN here (loopback: connect → drop → backoff redial → assert a SECOND full userauth occurred via the mirror auth delegate's attempt counter) but carries NO @spec ID yet (W4 promotes).
- Test: reconnect loopback cycle as above; a `VirtualClock`-driven unit test that a dead connection + backoff produces exactly one re-negotiation per attempt (no storm).

Commit `feat(mobile): SSH reconnect re-negotiates signaling; background invalidates the connection (IPAD-5.x)`.

### Task 5: End-to-end loopback + comment sweep + SPECS

**Files:**
- Test: extend the SSH loopback suite — full compact-path story in one process: paired Host fixture → coordinator with loopback-routed signaling transport (offer handed to the answerer peer mirror) → `SessionClient.live` factory → terminal bytes round-trip → kill peer → automatic re-negotiation → bytes flow again.
- Modify: stale comments — `IPadAppState.swift:98-109` (cache-stays-empty story now false / registry superseded), `SessionLifecycleEnvironment.swift` iPhone-path comments (:41-45, :96-99), `RootView.swift:445-454` fallback comment; grep "signaling lands"/"R6's iPhone cutover" for other stale references.
- `scripts/generate-specs.py` + SPECS.md; full mac suite; full iOS suite.

Commit `test(mobile): end-to-end signaling→SSH→reconnect loopback + comment sweep`.

---

## Self-review notes

- Task order is dependency-driven: observability (T1) before coordinator eviction (T2) before UI (T3) before reconnect (T4) before E2E (T5).
- The single-connection host (`HostError.busy`) means a SECOND device negotiating while one is connected falls back to `/ws` by design this milestone — observable via the 503 + warning log, not silent. Multi-connection host agent is a named non-goal (program plan).
- `/ws` stays fully functional — it is the fallback AND the browser path; nothing here touches WebServer routes.
- Out of scope: REMOTE-2.1 ID promotion + revocation registry (W4); `/ws`-retirement spec rewrite + ChannelRouter deletion (W5); multi-connection host; TURN/STUN.

## Risks

1. **`RemoteHostConnection` init/threading**: setting an observer post-init but pre-`createOffer` must be race-free on the actor — keep the observer an actor-isolated property set via an async call before negotiation starts.
2. **Preview pool fan-out**: iPad previews opening N SSH session channels through one connection is exactly the M8 surface-budget scenario (≤8) — the coordinator returns the SAME connection per host, so channels multiplex; verify channel-count behavior in the E2E rather than assuming.
3. **Foreground rebuild vs in-flight negotiation**: scenePhase flapping (quick background/foreground) can interleave invalidate with an in-flight negotiate — the coordinator's in-flight dedup must handle invalidate-during-negotiation (cancel or let-finish-then-evict; pick one, test it).
4. **Loopback signaling mirror**: the E2E's "signaling transport" hands the offer to an in-process answerer mirror (GrafttyHostAgent unavailable on iOS) — codec parity with the real `/v1/rtc/offer` handler stays a W6 smoke item, same as W2's mirror caveat.
