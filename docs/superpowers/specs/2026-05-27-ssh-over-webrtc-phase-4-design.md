# SSH-over-WebRTC R4 — Terminal Session Channel (iPad Cutover)

**Status:** Approved, 2026-05-27
**Parent design:** [`2026-05-21-ssh-over-webrtc-design.md`](2026-05-21-ssh-over-webrtc-design.md) (§8.1, §11 R4 row, §13)
**Predecessors landed:** R1 (Ed25519 migration, PR #198), R2 (SSHNIOTransport adapter, PR #199), R3 (userauth + cipher allowlist, PR #200)

## 1. Purpose

Wire SSH-over-WebRTC into the iPad's terminal path. This is the **first production WebRTC traffic** in graftty — R2 and R3 added the SSH stack but only exercised it in loopback tests. R4 makes an iPad attached to a paired Mac talk to that Mac's PTYs over `WebRTC DataChannel → SSH session channel → zmx attach`.

iPhone continues using `/ws`. R6 cuts iPhone over and deletes `/ws` + `ChannelRouter*`.

## 2. Correction to the parent design

Parent design §11 row R4 reads "RemoteHostConnection swapped from ChannelRouter to SSH for terminal." That phrasing implies `ChannelRouter` already carries production iPad terminal traffic. It does not — PR #176 landed `ChannelRouter` + `TerminalChannelHandler` as framing types, but neither `RemoteHostConnection` (mobile) nor `WebRTCHostAgent` (Mac) ever wired them into the live DataChannel. The only consumers today are loopback tests.

So R4 is the first PR where the iPad client opens a real production protocol session over WebRTC. The R4 commit message + the parent design's §11 R4 row both get a one-line clarification noting this; no other parent-design text changes.

## 3. Scope

**In:**

1. **NEW** `Sources/GrafttyHostAgent/SSH/Channels/TerminalSessionHandler.swift` — server-side SSH channel handler. Reads `GRAFTTY_SESSION` env, accepts `pty-req` (TERM/cols/rows), accepts `shell`, calls injected closure `(String) async throws -> TerminalByteStream` to attach to the pane, bridges bytes both ways, plumbs `window-change` to `stream.resize(cols:rows:)`. SSH channel close → kills the spawned `zmx attach` Process; the user's shell survives in the zmx daemon (parity with `/ws`'s `WebSession.close()`).
2. **NEW** `Sources/GrafttyMobileKit/Remote/SSH/Channels/TerminalSessionClient.swift` — mobile-side. Conforms to `WebSocketClient` so `SessionClient` consumes it unchanged. Init takes the per-connection SSH client + sessionName; on connect, opens the session channel, sends `env GRAFTTY_SESSION=<name>` → `pty-req` → `shell`. `send(.binary)` writes to the channel; `receive()` returns the next channel chunk wrapped in `.binary`; `close()` closes the channel. A `resize(cols:rows:)` method issues `window-change`.
3. **MODIFY** `Sources/GrafttyHostAgent/WebRTCHostAgent.swift` — after the DataChannel transitions to `open`, install R3's `SSHServerSetup` with a channel-handler factory that returns `TerminalSessionHandler(streamFactory:)`. `streamFactory` is a new init parameter on the host agent.
4. **MODIFY** `Sources/Graftty/GrafttyApp.swift` — when constructing `WebRTCHostAgent`, pass a closure `{ sessionName in spawn zmx attach <sessionName>, return TerminalByteStream }`. Spawn logic is a direct port of `WebSession.start()`'s `Process` construction — **copied, not extracted**. R6 consolidates after `/ws` deletion.
5. **MODIFY** `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift` — after the DataChannel transitions to `open`, install R3's `SSHClientSetup`. Expose `openTerminalSession(sessionName:) async throws -> TerminalSessionClient`.
6. **MODIFY** `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift` — `SessionClient.live(baseURL:sessionName:role:remoteHost:)` gains a `remoteHost: RemoteHostConnection?` parameter. When non-nil, `webSocketFactory` returns `try await remoteHost.openTerminalSession(sessionName:)`. When nil, the existing `URLSessionWebSocketClient` path runs unchanged.
7. **MODIFY** `Sources/GrafttyMobileKit/App/RootView.swift` — two `SessionClient.live(...)` call sites. Pass the per-host `RemoteHostConnection` when iPad has one; nil otherwise. iPhone path resolves to nil and stays on `/ws`.
8. **NEW** `Tests/GrafttyMobileKitTests/Remote/SSH/SSHTerminalLoopbackTests.swift` — extends R3's `runAuthLoopback` pattern. Real `zmx daemon` in a tmp dir, real `zmx attach` spawned by the server-side factory, write `printf 'hi\n' | cat` over the SSH session channel, expect `hi\n` echoed back. `.timeLimit(.minutes(1))`. iOS-only (UIKit-guarded).
9. **NEW** `Tests/GrafttyHostAgentTests/SSH/TerminalSessionHandlerTests.swift` — Mac-runnable unit tests. `TerminalSessionHandler` in an embedded NIO channel against a fake `TerminalByteStream`. Confirms env→pty→shell parsing, window-change forwarding, channel-close kills the stream, factory-throws sends `exit-status: 1`.

**Out:**

- iPhone. Stays on `/ws` until R6.
- `panes-state` and `pane-control` SSH channels (R5).
- `/ws` deletion (R6).
- `ChannelRouter` / `ChannelFrame` / `ChannelID` / `TerminalChannelOpenMeta` / `TerminalChannelHandler` deletion (R6).
- Promotions of `REMOTE-2.1`, `REMOTE-3.1`, `REMOTE-5.1` — each must hold for both transports (iPad + iPhone) before promotion. iPhone still on `/ws` makes them false text in R4. R6 promotes.

## 4. Architecture

```
                    iPad (GrafttyMobileKit)              Mac (Graftty + GrafttyHostAgent)
                    ━━━━━━━━━━━━━━━━━━━━━━              ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  RootView                                          WebRTCHostAgent
     │                                                 │
     │ SessionClient.live(remoteHost: conn)            │
     ▼                                                 │
  SessionClient                                        │
     │                                                 │
     │ webSocketFactory()                              │
     ▼                                                 │
  RemoteHostConnection.openTerminalSession(name)       │
     │                                                 │
     │ (uses SSHClientSetup from R3)                   │ (uses SSHServerSetup from R3)
     ▼                                                 ▼
  NIOSSHClient ─────────[DataChannel via SSHNIOTransport from R2]─────────► NIOSSHServer
     │                                                                          │
     │ open session channel                                                     │
     │ env GRAFTTY_SESSION=<name>                                               │
     │ pty-req (TERM, cols, rows)                                               │
     │ shell                                                                    ▼
     │                                                                  TerminalSessionHandler
     │                                                                          │
     │                                                                  streamFactory(name)
     │                                                                          │
     │                                                                          ▼
     │                                                                  Process(zmx attach <name>)
     │                                                                          │
     │                                                                         PTY ◄─► zmx daemon
     ▼                                                                                    │
  TerminalSessionClient                                                                   │
     │                                                                                    │
     │ conforms to WebSocketClient                                                 user's shell
     │ (unchanged consumers downstream:                                            (survives across
     │  SessionClient, SurfaceHandle, etc.)                                         attach cycles)
```

**Three layering invariants:**

1. `TerminalSessionClient` conforms to `WebSocketClient` (3-method protocol: `send` / `receive` / `close`). No adapter type; no platform branching downstream of `SessionClient.live`.
2. `TerminalSessionHandler` mirrors `WebSession`'s lifecycle: channel close kills `zmx attach`; shell survives in zmx daemon.
3. No new dependencies, no new spec promotions, no parent-design architectural changes.

## 5. Channel lifecycle (data flow)

One SSH session channel per attached pane. The iPad concurrency budget (`MobileSurfaceBudget` caps at 8 visible surfaces) is the natural ceiling on concurrent channels per host.

| Phase | Mobile side | Host side |
|---|---|---|
| **Open** | Send env `GRAFTTY_SESSION=<name>` → `pty-req` → `shell`. | env-request callback stores env on channel context. On `shell`, look up `GRAFTTY_SESSION`, invoke `streamFactory(name)`, attach. |
| **Steady state** | Byte writes → SSH channel data. `receive()` returns next chunk as `.binary(Data)`. | Server forwards channel data → `stream.send(bytes:)`. `stream.inboundBytes` → SSH channel data. |
| **Resize** | `window-change` request with new cols/rows. | `stream.resize(cols:rows:)`. |
| **Close (client)** | User navigates away. `RootView` drops `SessionClient`. `TerminalSessionClient.close()` closes the channel. | Channel close → kill `zmx attach` Process. Shell survives in zmx daemon. |
| **Close (server)** | `receive()` throws. `SessionClient` surfaces existing "session ended" path. | `zmx attach` exits (e.g., daemon went away). Send `exit-status` + close channel. |
| **Reconnect** | Per parent §9.1: full SSH KEX + userauth + channel re-open on `RemoteHostConnection` rebuild. Re-issue env+pty+shell with same sessionName. | Same — re-attach to the same pane in zmx daemon. State preserved. |

## 6. Error handling

| Failure | Server behavior | Client surface |
|---|---|---|
| Channel-open rejected (capability check from R3) | `SSH_OPEN_ADMINISTRATIVELY_PROHIBITED` | `TerminalSessionClient` init throws; `SessionClient.live` factory throws; existing path surfaces it |
| `streamFactory(name)` throws (daemon missing, sessionName not found, fork fails) | `exit-status: 1` + close channel | `receive()` throws on the next call |
| SSH-level reconnect (DataChannel reopens after network blip) | Full re-KEX + userauth + channel re-open per parent §9.1 | Transparent. `SessionClient` re-issues env+pty+shell. Pane state preserved in zmx daemon. |

## 7. Test strategy

- **`SSHTerminalLoopbackTests.swift`** (iOS-only). Extends R3's `runAuthLoopback` infrastructure. Real `RTCPeerConnection` pair + real SSH stack; the `streamFactory` returns a fake echoing `TerminalByteStream` rather than spawning `zmx attach` (iOS Simulator doesn't have host binaries). Exercises the SSH wire end-to-end: env→pty→shell, bytes round-trip both directions, `window-change` forwarding, channel-close kills the stream. `.timeLimit(.minutes(3))` per R3 precedent (iOS CI variance). Real `zmx attach` integration is verified at the manual TestFlight gate, not in CI.
- **`TerminalSessionHandlerTests.swift`** (Mac-runnable, embedded NIO channel). Unit tests for the handler against a fake `TerminalByteStream`. Confirms env→pty→shell parsing, `window-change` forwarding, channel-close kills the stream, factory-throws produces `exit-status: 1`.
- **No mocking of SSH primitives or `zmx`** in the iOS loopback (parent design §13.2; user feedback `feedback_don't_mock_database`).
- **macOS `swift test` is insufficient** for the loopback (UIKit-guarded). iOS Simulator via `xcodebuild` is the canonical CI gate, per `feedback_macos_swift_test_misses_uikit_guarded_code`.
- **Manual TestFlight gate.** R4 is the first production WebRTC traffic. Build the Mac app, install on a TestFlight iPad, pair, attach to a worktree, type a command, confirm output. The loopback test does not substitute for this — only real-network verification confirms the iPad ↔ Mac path end-to-end. This is a step in the R4 plan, not a CI gate.

## 8. Spec impact

**Promotions: none in R4.**

The promotions in flight (`REMOTE-2.1`, `REMOTE-3.1`, `REMOTE-5.1`) all gate on both transports satisfying their EARS text. While iPhone still uses `/ws`, R4 cannot promote them.

**Text edits: one line in parent design.** §11 row R4's description gets clarified ("RemoteHostConnection wired to SSH for terminal; this is the first production protocol over the DataChannel — `ChannelRouter` was never wired into production").

## 9. Risks

1. **Two `zmx attach` Process spawns coexist** (`WebSession.start()` for `/ws`; the new R4 closure for SSH). Intentional duplication, target <30 lines per side; R6 consolidates after `/ws` deletion. Risk: drift between the two spawns. Mitigation: keep both spawns simple and side-by-side reviewable; revisit at R6.
2. **iPad reconnect-during-shell.** R3 + parent §9.1 cover the protocol; R4 inherits via `RemoteHostConnection` reconnect. New failure surface: session channel open mid-handshake. Loopback test should cover at least one reconnect cycle.
3. **First production WebRTC traffic.** R2/R3 only ran loopback tests. R4 is the first PR where a real iPad talks to a real Mac over WebRTC + SSH for a user-visible behavior. Manual TestFlight verification is required — see §7.
4. **iPad's `SessionClient.live` signature change.** Adding `remoteHost: RemoteHostConnection?` is source-compatible (defaulted to `nil`), but both iPad call sites must pass the right value or iPad falls back to `/ws` silently. Mitigation: log when `remoteHost == nil` on iPad so a wiring regression is visible in console.

## 10. Decisions summary

| Topic | Decision |
|---|---|
| Pane attach mechanism | SSH `env GRAFTTY_SESSION=<name>` channel request, then `pty-req`, then `shell`. |
| `WebSocketClient` integration | `TerminalSessionClient` directly conforms to `WebSocketClient`. No adapter. |
| `zmx attach` spawn dedup | Intentionally duplicated for R4; R6 consolidates after `/ws` deletion. |
| iPhone in R4 | Unchanged. Stays on `/ws`. |
| Spec promotions in R4 | None. R6 promotes `REMOTE-2.1`, `REMOTE-3.1`, `REMOTE-5.1` together. |
| Delivery shape | Single PR. Loopback test + production wiring + iPad cutover, mirrors R2/R3. |
| Manual TestFlight gate | Required. First production WebRTC traffic; loopback test alone is insufficient. |
| Logging on factory fallback | iPad logs when `remoteHost == nil` on `SessionClient.live` — catches a wiring regression silently falling back to `/ws`. |
