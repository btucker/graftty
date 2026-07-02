# WebRTC Landing Wrap-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan milestone-by-milestone. This is a **program-level plan**: each W-milestone below is one PR and gets its own bite-sized RED/GREEN plan doc (`docs/superpowers/plans/2026-MM-DD-webrtc-wrapup-wN-*.md`) written immediately before execution, following the same convention as the R1–R5 milestone plans.

**Goal:** Make the already-landed SSH-over-WebRTC stack (R1–R5) actually carry production traffic for native clients, with pairing UX, revocation, and a shared terminal core — while keeping `/ws` as the browser transport behind a thin compatibility layer.

**Architecture:** Native clients (iPhone + iPad) pair via the existing QR local-network ceremony, negotiate a WebRTC DataChannel via the host's `/v1/rtc/offer` endpoint, and run SSH (auth + channels) over it. The browser web client keeps `/ws`. Both transports terminate in one shared host-side terminal-attach core (zmx attach + display ownership); the WebSocket and SSH sides become thin framing adapters over that core.

**Tech Stack:** swift-nio-ssh 0.13, stasel/WebRTC, SwiftNIO, Swift Testing (`@spec` EARS convention), existing `HostPairingServer`/`LocalPairingClient` protocol layer.

## Global Constraints

- Every PR that touches `GrafttyMobileKit` requires **iOS CI green** before merge — macOS `swift test` false-greens UIKit-guarded code (`feedback_macos_swift_test_misses_uikit_guarded_code`).
- Run `scripts/generate-specs.py` and commit `SPECS.md` alongside every spec change; never edit `SPECS.md` by hand.
- No literal `\"` quotes in `@spec` test titles (silently truncates SPECS.md).
- Web-client source changes require `./scripts/build-web.sh` (pnpm) + committing regenerated `Sources/GrafttyKit/Web/Resources/app.js|css`, or the `verify-web` CI job fails.
- New linked frameworks (none expected) must be added to `scripts/bundle.sh` manually — CI does not run it.
- Follow RED/GREEN TDD per CLAUDE.md: promote `@Test(.disabled(...))` from `*Todo.swift` → failing test → implementation.
- Run `/code-review xhigh --fix` before opening each PR.

---

## Where we actually are (audit, 2026-07-01)

### Landed and real (merged PRs)

| Milestone | PR | What it delivered |
|---|---|---|
| Phase 1 pairing protocol | #173, #174 | Identity stores, `TrustedPeerStore`, `PinnedHostStore`, `HostPairingServer` + `LocalPairingClient` (QR ceremony wire format, REMOTE-1.1/1.2) |
| M1.1 WebRTC SDK | #176 | `RemoteHostConnection` / `WebRTCHostAgent` actors, loopback harness |
| M1.2 signaling | (in #176/#202 line) | Host `POST /v1/rtc/offer` route wired to `WebRTCHostAgent.acceptOffer` (`GrafttyApp.swift:1586`); mobile `SignalingClient` exists |
| R1 Ed25519 keys | #198 | X25519 → Ed25519 identity migration, versioned key JSON |
| R2 SSH transport | #199 | `SSHNIOTransport` NIO↔DataChannel adapter, loopback `exec` gate passed |
| R3 userauth | #200 | `SSHUserAuthDelegate` (key-only identity, capability check), host-key pinning, AEAD ciphers |
| R4 terminal channel | #202 | `TerminalSessionHandler`/`TerminalSessionClient` (conforms to mobile `WebSocketClient` protocol), `SessionClient.live(remoteHost:)` branch |
| R5 subsystem channels | #203 | `panes-state@graftty.dev` + `pane-control@graftty.dev`, `PaneEnvironment` plumbing, REMOTE-6.1/7.1 promoted |

### Claimed or assumed, but **not** real

1. **No production traffic rides SSH.** `IPadAppState.remoteHostConnectionsByHostId` "stays empty" in production (its own doc comment, `IPadAppState.swift:103-108`) — no mobile code ever calls `SignalingClient`/`createOffer`/`applyAnswer`/`setRemoteHostConnection`. iPad *and* iPhone are both on `/ws` today.
2. **Pairing has no UX.** `LocalPairingClient` and `TrustedPeerStore.add` have zero production callers; `HostPairingServer`'s `/introduce` + `/await-outcome` handlers are mounted on no HTTP route. There is no way to establish trust in the shipping app, so SSH userauth can never succeed outside tests.
3. **REMOTE-7.6 was not promoted in R5** despite the PR body: revocation teardown (`triggerUserInitiatedClose`) appears nowhere in Sources/Tests; there is no registry of live SSH connections by peer.
4. **The SSH terminal path bypasses display ownership.** `ZmxAttachStream` is registered as accounting-only (`GrafttyApp.swift` R4 comment); `declaredDisplayClientKind` / `SessionDisplayOwnershipStore` semantics exist only on the `/ws` path. An iPhone cut over to SSH today would lose Take Control / ownership.
5. **LAN-only reachability.** `RemoteHostConnection` and `WebRTCHostAgent` both set `iceServers = []` (host candidates only), and signaling requires reaching the host's local HTTPS endpoint. The "Tailscale alternative" promise requires Phase 4 (cloud signaling + STUN/TURN via graftty-server) — **explicitly out of scope here**; this wrap-up delivers the transport, trust, and UX layers Phase 4 plugs into.

### Decisions (2026-07-01, supersede parts of the 2026-05-21 design)

| Decision | Choice | Why |
|---|---|---|
| `/ws` fate | **Keep it** for the browser web client; native clients prefer SSH-over-WebRTC with `/ws` as explicit fallback | User decision 2026-07-01. Web UI is actively invested (WEB-4.x, verify-web gate); the May-15 "web UI deprecation" section is overtaken by events |
| REMOTE-5.1 | **Rewrite**, don't promote as written | "Retired `/ws` endpoint" no longer matches product direction; see spec transitions below |
| Code sharing | One shared host-side terminal-attach core; `/ws` and SSH become thin framing adapters | User directive: "as much shared code between it and the new webrtc system as possible; ideally a small compatibility layer" |
| Initial key exchange | Existing QR local-network ceremony, unchanged | Already designed + protocol landed; QR carries host-key fingerprint so no rendezvous/discovery service is needed for security. Bonjour discovery is a possible later convenience, not part of this wrap-up |
| Pairing reachability | Pairing routes served only while a pairing session is active | Minimizes standing attack surface on the host HTTP server |

---

## Milestones

Sequenced so each PR is independently shippable and no traffic flips before its dependencies are in place: **pairing → shared core → signaling/cutover → revocation → cleanup → device gate**.

### W1 — Pairing UX (host + mobile)

The trust-establishment on-ramp. After W1, a user can pair an iPhone/iPad with the Mac on the same LAN and the host persists a `TrustedPeer`.

**Files:**
- Modify: `Sources/GrafttyKit/Web/WebServer.swift` — mount `POST /v1/pair/introduce` and `POST /v1/pair/await-outcome`, delegating to an injected `HostPairingServer?` (nil ⇒ 404; routes live only while a pairing session is active)
- Modify: `Sources/Graftty/Web/WebServerController.swift` — pairing-server injection point (same pattern as `setSignalingHandler`, `WebServerController.swift:156`)
- Modify: `Sources/Graftty/Web/WebSettingsPane.swift` — "Pair a device…" section: starts `HostPairingServer.start(validFor:)`, renders the `PairingPayload` QR via existing `QRCodeView`, shows fingerprint + confirm/deny buttons driving `confirm()`/`deny()`
- Modify: `Sources/GrafttyMobileKit/Hosts/AddHostView.swift` — recognize a pairing QR payload (vs plain Graftty-URL QR), drive `LocalPairingClient.runPairing`, show REMOTE-1.2 verification code + host fingerprint confirmation
- Modify: `Sources/GrafttyMobileKit/Hosts/Host.swift` — persist the paired host's `RemoteDeviceID` + pinned fingerprint reference on the `Host` record so later milestones can map `Host` → SSH identity
- Test: `Tests/GrafttyTests/Remote/Pairing/PairingRouteTests.swift` (host route mounting/404-when-inactive), plus mobile-side pairing-flow tests in `Tests/GrafttyMobileKitTests/`

**Interfaces:**
- Consumes: `HostPairingServer.start(validFor:) throws -> PairingPayload`, `.confirm() throws -> TrustedPeer`, `.deny()`, `.handleIntroduce(...)`, `.handleAwaitOutcome(...)` (all existing, `HostPairingServer.swift:57-175`); `LocalPairingClient` (existing)
- Produces: paired `Host` records carrying remote identity; `TrustedPeerStore` entries on the Mac. New spec IDs REMOTE-1.3 (host persists confirmed peer), REMOTE-1.4 (pairing routes inactive ⇒ rejected) — exact EARS text drafted in the W1 plan doc.

**Exit criteria:** real iPhone pairs with real Mac over LAN; `trusted-peers.json` gains the peer; denial and expiry paths surfaced in both UIs; iOS CI green.

### W2 — Shared terminal core + ownership parity (host-side refactor, no traffic flip)

The compatibility-layer directive. Pure refactor: `/ws` behavior is unchanged, SSH path gains ownership semantics, duplication deleted.

**Files:**
- Create: `Sources/GrafttyKit/Remote/TerminalAttachCore.swift` — one type owning: zmx attach stream lifecycle (absorbing the intentional R4 duplication between `GrafttyKit.WebSession` and `Graftty/Remote/ZmxAttachStream.swift` — its own header says "R6 consolidates after `/ws` deletion"), `RemoteAttachmentRegistry` accounting, and `SessionDisplayOwnershipStore` attach/claim/resize/detach calls currently inlined in `WebSocketBridgeHandler` (`WebServer.swift:101-253`)
- Modify: `Sources/GrafttyKit/Web/WebServer.swift` — `WebSocketBridgeHandler` becomes a framing adapter: WS text/binary frames + `client=` query param in, `TerminalAttachCore` calls out
- Modify: `Sources/GrafttyHostAgent/SSH/…` (`SubsystemDispatcher` / `TerminalSessionHandler`) — same core behind SSH channel framing; SSH-attached clients get `DisplayClientKind.ios` and full ownership protocol (snapshots ride the existing session channel or `panes-state` envelope — decided in the W2 plan doc)
- Modify: `Sources/Graftty/GrafttyApp.swift:352-380` — `streamFactory` now builds through the core, deleting the "registry is accounting only" carve-out
- Delete: `Sources/Graftty/Remote/ZmxAttachStream.swift` (absorbed)
- Test: core unit tests (ownership transitions per transport kind), existing `/ws` tests must pass unchanged — they are the regression harness proving the adapter is faithful

**Interfaces:**
- Produces: `TerminalAttachCore` API (attach/detach/resize/claimOwner keyed by session + client kind) — exact signatures drafted in W2 plan doc; consumed by both adapters and by W3's iPhone cutover.

**Exit criteria:** `swift test` + iOS CI green; web client manual smoke (terminal, Take Control, resize) unchanged; SSH loopback tests now assert ownership snapshots.

### W3 — Mobile signaling wiring + native cutover (traffic flip)

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/IPadAppState.swift` → generalize the connection registry for both size classes (rename or extract, e.g. `RemoteConnectionRegistry`); construction site: on host connect for a paired `Host`, run `RemoteHostConnection.createOffer()` → `SignalingClient` POST → `applyAnswer(_:)` → `setRemoteHostConnection(_:for:)`
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift:444-468` + `SessionLifecycleEnvironment.swift:46-64` — iPhone (compact) path passes the registry too; `SessionClient.live` keeps the existing shape: SSH when a connection is registered, `/ws` fallback otherwise (fallback now logs + surfaces a subtle indicator rather than being silent)
- Modify: `buildPaneEnvironment` call sites so the iPhone path populates `PaneEnvironment` as R5's comment anticipated (`SessionLifecycleEnvironment.swift:75-76`)
- Reconnect: on `RTCPeerConnection` failure / app foreground, tear down and re-negotiate (full SSH KEX+userauth per design §9.1); reuse `SessionReconnectTests` backoff patterns
- Test: iOS loopback end-to-end (pair → signal → SSH terminal on compact path); reconnect cycle test asserting fresh userauth (this is the RED test for REMOTE-2.1, promoted in W4)

**Exit criteria:** paired iPhone + iPad terminals ride SSH on real devices (verify via host-side `RemoteAttachmentRegistry` / logs); unpaired devices still work via `/ws`; iOS CI green.

### W4 — Revocation teardown + security spec promotions

**Files:**
- Create: `Sources/GrafttyHostAgent/SSHConnectionRegistry.swift` — `RemoteDeviceID` → live `NIOSSHHandler` map (`WebRTCHostAgent` is single-connection today, `HostError.busy`; registry keys by peer so multi-agent support in a later milestone slots in)
- Modify: `WebRTCHostAgent.swift` — register at userauth success (identity already resolved in `SSHUserAuthDelegate`), deregister on close
- Modify: host revocation call sites (`TrustedPeerStore.remove/update`) — invoke `handler.triggerUserInitiatedClose()` on matching live connections; add host-side "Paired Devices" management UI listing `TrustedPeerStore.list()` with revoke, if no surface exists yet
- Promote: REMOTE-2.1 (test written in W3), REMOTE-3.1, REMOTE-7.6 from `Tests/GrafttyTests/Specs/RemoteTodo.swift` → real tests in `Tests/GrafttyTests/Remote/SSH/`
- Run `scripts/generate-specs.py`

**Exit criteria:** loopback test: revoke mid-session ⇒ channels close within one tick, next userauth fails; all three specs active; SPECS.md regenerated.

### W5 — Dead-code deletion + spec realignment

**Files:**
- Delete: `Sources/GrafttyKit/Remote/ChannelRouter.swift`, `Sources/GrafttyKit/Remote/TerminalChannelHandler.swift`, `Sources/GrafttyProtocol/ChannelFrame.swift`, `ChannelFrameCoder.swift`, `ChannelID.swift`, `TerminalChannelEnvelope.swift` (zero production references — M1.4 layer superseded by SSH channels)
- Delete: their tests — `ChannelRouterTests.swift`, `ChannelRouterOpenCleanupTests.swift`, `ChannelRouterTestSupport.swift`, `TerminalChannelHandlerTests.swift`, `ChannelFrameCoderTests.swift`
- Rewrite REMOTE-5.1 in `RemoteTodo.swift` (then promote): replace "retired `/ws` endpoint" with the kept-`/ws` reality, e.g. *"While a session terminal is served over `/ws`, the application shall route it through the same terminal-attach core as SSH-attached clients, applying identical display-ownership rules."* Exact EARS text finalized in the W5 plan doc; add a companion spec pinning that `/ws` remains subject to `WebAccessAuth` (`auth.isAllowed(peer)`, `WebServer.swift:758`)
- Audit stale comments referencing "R6 deletes /ws" (`ZmxAttachStream` header is deleted in W2; `GrafttyApp.swift:221` post-R6 teardown-hook note; `SessionLifecycleEnvironment` comments)
- Run `scripts/generate-specs.py`

**Exit criteria:** `grep -rn "ChannelRouter\|ChannelFrame" Sources/` returns nothing; SPECS.md reflects the new REMOTE-5.1; full suite green.

### W6 — Real-device validation gate (no code)

Design §13.5's gate, adapted: TestFlight build; verify on (a) same-LAN Wi-Fi, (b) Tailscale-reachable host (signaling over tailnet, DataChannel over host candidates), (c) revoke-while-attached from the Mac UI, (d) browser web client regression pass. Document results in `docs/ZmxWebAccessSmokeChecklist.md`-style checklist. **This gate, not W5, closes the program.**

---

## Spec transitions (net of this program)

| Spec | Today | After |
|---|---|---|
| REMOTE-2.1 reconnect re-auth | disabled | **Promoted** (W3 test, W4 promotion) |
| REMOTE-3.1 revocation closes channels | disabled | **Promoted** (W4) |
| REMOTE-5.1 `/ws` retired | disabled | **Rewritten + promoted** — `/ws` kept, shared-core + auth parity (W5) |
| REMOTE-7.6 revocation closes pane_control | disabled | **Promoted** (W4) |
| REMOTE-1.3/1.4 pairing UX | — | **New** (W1) |
| REMOTE-4.1/4.2 port tunnels | disabled | Unchanged (out of scope) |
| REMOTE-8.1 strict KEX pin | disabled | Unchanged (awaits upstream swift-nio-ssh) |

## Risks

1. **Ownership-over-SSH design (W2)** is the least-specified piece: `/ws` interleaves ownership JSON with terminal bytes on one socket; SSH separates terminal (session channel) from state (`panes-state`). W2's plan doc must pick one shape before code. Mitigation: the existing `/ws` tests define the semantics; only the carrier changes.
2. **Single-connection `WebRTCHostAgent`** means iPhone + iPad can't both ride SSH simultaneously (second offer ⇒ `busy`). W3 should surface this gracefully (second device falls back to `/ws`); multi-agent host is a named follow-up, not silently deferred.
3. **Pairing-QR vs URL-QR ambiguity in AddHostView** — payload discrimination must be explicit or users scanning the wrong settings QR get confusing failures.
4. **Traffic flip regressions (W3)** — mitigated by the `/ws` fallback remaining fully functional (it's now the tested shared core) and by the W6 gate.
5. **Phase 4 expectations** — after this program, remote access still requires LAN or Tailscale reachability for signaling + ICE. The true "no-Tailscale" story is graftty-server cloud signaling + STUN/TURN, tracked separately.
