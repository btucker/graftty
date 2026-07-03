# W4 — Revocation Teardown + Spec Promotions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Revoking a paired device on the host closes that peer's live SSH connection immediately (not just rejecting its next attach), and REMOTE-2.1/3.1/7.6 become active specs.

**Architecture:** Today the host already rejects a revoked peer's *future* userauth (the fingerprint vanishes from `TrustedPeerStore`), but a peer revoked *mid-session* keeps its live SSH connection until it drops on its own. W4 adds a peer→transport registry so the "Remove" button in the host's Paired Devices UI can close the revoked peer's SSH parent channel — which cascades to all child channels (terminal, panes-state, pane-control) and, via the agent's own teardown, the WebRTC DataChannel. Because the pinned swift-nio-ssh has **no `triggerUserInitiatedClose`**, teardown is "close the parent SSH channel," which the existing `WebRTCHostAgent.close()` / `SSHNIOTransport.performClose()` path already performs.

**Tech Stack:** swift-nio-ssh 0.13, SwiftNIO, `NIOAsyncTestingChannel`/`NIOEmbedded` for WebRTC-free tests, Swift Testing.

## Global Constraints

- **NEVER initialize native libwebrtc in a mac-CI test.** `RTCPeerConnectionFactory`/`RTCPeerConnection` hang the headless GitHub macOS runner (cost W3 two CI fix rounds). Revocation tests use `NIOAsyncTestingChannel` + a real `NIOSSHHandler`/`SSHServerSetup.makeHandler`, never `WebRTCHostAgent.acceptOffer` or `SSHNIOTransport.init(dataChannel:)`. Precedent: `TerminalSessionHandlerTests.channel(_:)` (`:904-911`), `SSHUserAuthCapabilityTests` (bare `EmbeddedEventLoop`).
- iOS CI green for any `GrafttyMobileKit` change (none expected — W4 is host-side).
- `scripts/generate-specs.py` + commit `SPECS.md`; EARS phrasing; no literal escaped quotes in `@spec` titles; a spec ID appears in at most one behavioral location (REMOTE-2.1's behavior is proven by an existing `@spec IPAD-5.2` test — do NOT double-tag; see Task 4).
- Strict concurrency, warnings-as-errors; RED/GREEN TDD; commit per green task; `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; `/code-review xhigh --fix` after opening the PR.

## Key facts (survey-verified @ 9c3c5e9)

- `triggerUserInitiatedClose` DOES NOT EXIST in pinned swift-nio-ssh (`1a915a324`). Teardown = close the parent SSH channel → `NIOSSHHandler.channelInactive` cascades to child channels. `WebRTCHostAgent.close()` (`Sources/GrafttyHostAgent/WebRTCHostAgent.swift:224`) → `transport.close()` → `SSHNIOTransport.performClose()` (`SSHNIOTransport.swift:228,366`, `embedded.close`) is the existing whole-agent version.
- `WebRTCHostAgent` is single-connection (`peerConnection`/`dataChannel`/`sshTransport?` all singular; `acceptOffer` rejects a 2nd offer with `HostError.busy`). The `NIOSSHHandler` is added to the pipeline in `installSSHHandler` (`:268`, `SSHServerSetup.makeHandler` at `:309`) but NOT retained as a property — only `sshTransport` is.
- Authenticated peer identity: `AuthenticatedPeerBox` (`:284`, class `:418-426`), populated by `SSHUserAuthDelegate.onAuthenticated { deviceID in peerBox.deviceID = deviceID }` (`:291`) synchronously at userauth; today consumed only by `SubsystemDispatcher.deviceIDProvider` (`:303`). It is a local `let` inside `installSSHHandler` — NOT surfaced to any revocation entry point (the W4 gap).
- `SSHUserAuthDelegate` (`Sources/GrafttyHostAgent/SSH/SSHUserAuthDelegate.swift:34,50-62`): `onAuthenticated: (@Sendable (RemoteDeviceID) -> Void)?`; resolves via `store.get(fingerprint:)`; already rejects revoked/unpaired (the "future attach fails" half of REMOTE-3.1 — done + tested in `SSHUserAuthCapabilityTests`).
- `TrustedPeerStore.remove(id:)` (`Sources/GrafttyKit/Remote/TrustedPeerStore.swift:61`) is revocation; only production writer of remove is the UI.
- Host revoke UI EXISTS: `Sources/Graftty/Web/PairedDevicesSection.swift` — `remove(_:)` (`:303-310`) calls `trustedPeerStore.remove(id: peer.id)` then `refreshPeers()`. This is the wire-in point. Store shared with the agent via `GrafttyApp.swift:363/389`.
- Disabled inventory `Tests/GrafttyTests/Specs/RemoteTodo.swift`: REMOTE-2.1 (`:11-13`, reconnect fresh auth), REMOTE-3.1 (`:16-18`, revoke closes channels + rejects future), REMOTE-7.6 (`:36-38`, revoke closes pane_control). REMOTE-2.1's behavior is already proven by `invalidateThenReconnectProducesASecondFullUserauth` tagged `@spec IPAD-5.2` in `Tests/GrafttyMobileKitTests/Remote/RemoteConnectionReconnectTests.swift` (a real-WebRTC mobile test — NOT a headless seam).
- Test seam for close-cascade: install `SSHServerSetup.makeHandler(...)` onto a `NIOAsyncTestingChannel`, open a child channel, close the parent, assert the child goes inactive. No native WebRTC.

---

### Task 1: `SSHConnectionRegistry` — peer → live SSH connection

**Files:**
- Create: `Sources/GrafttyHostAgent/SSH/SSHConnectionRegistry.swift`
- Test: `Tests/GrafttyTests/Remote/SSH/SSHConnectionRegistryTests.swift`

**Interfaces (produces):**
```swift
/// Maps an authenticated RemoteDeviceID to a closable live SSH connection.
/// Single-connection today (WebRTCHostAgent), but keyed by peer so a
/// multi-connection host slots in without reshaping callers.
public actor SSHConnectionRegistry {
    public init()
    /// Register the peer's connection with a close action (the agent passes
    /// a closure that closes the SSH parent channel / transport). Replacing
    /// an existing entry for the same device closes the old one first.
    public func register(deviceID: RemoteDeviceID, close: @escaping @Sendable () async -> Void)
    public func deregister(deviceID: RemoteDeviceID)
    /// Close and remove the peer's connection if present (idempotent — a
    /// second revoke, or a revoke of a never-connected peer, is a no-op).
    public func revoke(deviceID: RemoteDeviceID) async
    public var count: Int { get }   // test observability
}
```

Steps: RED tests (no WebRTC — pure actor logic with a spy close-closure): register→revoke calls close + removes; revoke of absent id is a no-op; re-register same id closes the prior; count reflects state. GREEN implement. Commit `feat(remote): SSHConnectionRegistry — peer-keyed closable SSH connections`.

### Task 2: Wire the registry into `WebRTCHostAgent`

**Files:**
- Modify: `Sources/GrafttyHostAgent/WebRTCHostAgent.swift` — accept an `SSHConnectionRegistry` (init param, default a fresh one so existing callers/tests compile); in `installSSHHandler`, after userauth resolves the deviceID into `AuthenticatedPeerBox`, `register(deviceID:close:)` with a closure that closes THIS connection's `sshTransport` (and tears the agent down — reuse `close()`); deregister on `close()`/`channelInactive`.
- Modify: `Sources/Graftty/GrafttyApp.swift` — construct ONE shared `SSHConnectionRegistry`, pass to `WebRTCHostAgent` AND expose it where `PairedDevicesSection` can reach it (Task 3).
- Test: `Tests/GrafttyTests/Remote/SSH/SSHRevocationCascadeTests.swift` — the WebRTC-free close-cascade proof: build `SSHServerSetup.makeHandler` on a `NIOAsyncTestingChannel`, open a child (session or pane-control) channel, close the parent channel, assert the child goes inactive. This is the "closing the parent cascades" invariant the registry's close-closure relies on. (Does NOT exercise WebRTCHostAgent — that path is device-gated in W6.)

**Interfaces (consumes):** `AuthenticatedPeerBox.deviceID` (`:284`), `sshTransport` (`:45`), `close()` (`:224`).

Steps: RED the cascade test (open child, close parent, expect inactive — write it, watch it pass or reveal the mechanism); wire registration; ensure `deviceID` is non-nil at registration time (userauth precedes registration — the box is populated synchronously in `onAuthenticated` before channels open). Commit `feat(remote): host agent registers/deregisters its SSH connection by authenticated peer`.

### Task 3: Wire revocation UI → registry

**Files:**
- Modify: `Sources/Graftty/Web/PairedDevicesSection.swift` `remove(_:)` (`:303-310`) — after `trustedPeerStore.remove(id: peer.id)`, call `await registry.revoke(deviceID: peer.id)` (thread the shared registry into the section, matching how `trustedPeerStore` is injected at `WebSettingsPane`/`GrafttyApp:578`).
- Modify: `WebSettingsPane` + `GrafttyApp` injection to pass the registry.
- Test: the registry-close behavior is covered by Task 1; this task's correctness is the wiring (revoke button → registry.revoke). If a pure view-model seam exists, add a small test that `remove` calls both `store.remove` and `registry.revoke`; else verify by the end-to-end reasoning + build and note it (UI glue).

Steps: wire; `swift build`; manual-smoke note in report (revoke a paired device in Settings → its live session drops). Commit `feat(settings): revoking a paired device closes its live SSH connection`.

### Task 4: Promote REMOTE-3.1 + REMOTE-7.6 (headless close tests)

**Files:**
- Modify: `Tests/GrafttyTests/Remote/SSH/` — add the behavioral tests carrying the `@spec` IDs (verbatim EARS from RemoteTodo). REMOTE-3.1: revoke ⇒ registry closes the connection (parent channel closed → child channels inactive) AND a subsequent userauth for that fingerprint fails (reuse `SSHUserAuthCapabilityTests`' delegate-on-EmbeddedEventLoop pattern for the reject half; the close half via the Task-2 cascade seam). REMOTE-7.6: same but with a `pane_control` child channel open — assert it goes inactive on parent close.
- Delete the REMOTE-3.1 + REMOTE-7.6 entries from `Tests/GrafttyTests/Specs/RemoteTodo.swift` (same commit).
- Regenerate `SPECS.md`.

Steps: RED (IDs promoted, assertions fail until Tasks 1-3 land — but Tasks 1-3 precede this, so these should pass on write; if they fail that's a real integration gap, fix forward). `generate-specs.py --check` green. Commit `test(remote): promote REMOTE-3.1 + REMOTE-7.6 — revocation closes live channels`.

### Task 5: Promote REMOTE-2.1 (reconnect fresh auth)

**Files:**
- The behavior is already proven by `invalidateThenReconnectProducesASecondFullUserauth` (currently `@spec IPAD-5.2`, a real-WebRTC mobile test). REMOTE-2.1 and IPAD-5.2 are DIFFERENT requirements that the same test happens to exercise (a spec ID may appear in one behavioral location — so do NOT add `@spec REMOTE-2.1` to that same test). Options, decide in the task:
  (a) Add a **headless host-side** REMOTE-2.1 test: drive `SSHUserAuthDelegate` on an `EmbeddedEventLoop` twice (simulating reconnect) and assert each attach performs a fresh userauth before any PTY write — mirrors the spec text ("fresh authenticated attach handshake before writing any bytes to the PTY") at the host layer without WebRTC. This is the cleanest home for the ID and CI-safe.
  (b) If (a) can't honestly assert "before writing any bytes to the PTY" at the delegate layer, tag REMOTE-2.1 onto the TerminalSessionHandler-level test that gates PTY writes behind auth (find it) instead.
- Delete REMOTE-2.1 from `RemoteTodo.swift` (same commit); regenerate `SPECS.md`.

Steps: pick (a) or (b), justify in report; RED/GREEN; `--check` green. Commit `test(remote): promote REMOTE-2.1 — reconnect requires fresh authenticated attach`.

### Task 6: Comment sweep + SPECS

**Files:** stale comments referencing "triggerUserInitiatedClose" in any design/plan doc or code comment (the mechanism is parent-channel-close, not a handler method) — grep and correct; regenerate `SPECS.md`; full mac `swift test`.

Commit `docs(remote): revocation teardown is parent-channel-close (no triggerUserInitiatedClose in swift-nio-ssh)`.

---

## Self-review notes

- REMOTE-3.1's "reject future attach" half is ALREADY done + tested; W4 adds only the "close active channels" half + the promoted ID. Do not re-implement the reject half.
- The registry is peer-keyed despite the single-connection agent so W6/a future multi-connection host doesn't reshape it — YAGNI-adjacent but the spec text ("all active secure channels from that peer") reads at peer granularity, so the key is the honest shape.
- Out of scope: multi-connection host agent; REMOTE-4.x port tunnels; any WebRTC-path integration test (device-gated, W6).

## Risks

1. **Registration timing**: the deviceID must be in `AuthenticatedPeerBox` before `register` is called. `onAuthenticated` populates it synchronously during userauth, and channels (thus any revocable session) open only after userauth — so registering at the end of `installSSHHandler`'s success path is safe. Verify the box is non-nil there; if a race exists, register inside `onAuthenticated` itself.
2. **Close-closure retain cycle**: the registry's `@Sendable close` closure captures the agent/transport — ensure weak capture so the registry doesn't keep a torn-down agent alive; deregister on `close()`.
3. **CI hang regression**: any test that touches `WebRTCHostAgent.acceptOffer` or builds `SSHNIOTransport(dataChannel:)` will hang mac CI. All W4 tests use `NIOAsyncTestingChannel`/`EmbeddedEventLoop` only — enforce in review.
