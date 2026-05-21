# SSH-over-WebRTC for Graftty Remote Access

**Status:** Draft, 2026-05-21
**Supersedes:** Sections 7–9 of [`graftty-server/docs/superpowers/specs/2026-05-15-graftty-webrtc-secure-remote-access-design.md`](../../../../graftty-server/docs/superpowers/specs/2026-05-15-graftty-webrtc-secure-remote-access-design.md) (the Noise-based session handshake, the custom secure channel layer, and the bespoke channel framing).

## 1. Purpose and scope

Replace the deferred M1.3 Noise handshake and the shipped M1.4 `ChannelRouter` with an in-process `swift-nio-ssh` session running over the existing WebRTC DataChannel. SSH provides authenticated mutual identity, channel multiplexing with window/flow control, and standardized PTY semantics — three layers we were going to write ourselves.

The WebRTC DataChannel remains the transport. The WebRTC NAT-traversal story is unchanged; the only reason we are not on Tailscale or SSH-over-TCP is that some users cannot install a VPN on their work machines but can install the Graftty app, and WebRTC traverses NAT entirely inside the app's userspace.

The change extends down to the iPhone fullscreen terminal: the existing `/ws` `URLSessionWebSocketTask` bridge is retired in the same delivery, so the M2a `TerminalChannelHandler` shipped in PR #176 finally has a production consumer.

## 2. Non-goals

- **Replacing WebRTC.** The transport layer (signaling + ICE + DataChannel) is unchanged.
- **Phase 4 cloud-routed signaling.** `graftty-server`'s WebRTC v2 work is orthogonal; SSH is identical regardless of how the DataChannel was established.
- **iPad UI surfaces (M5–M9 from the iPad layout design).** Independent of the transport question.
- **Phase 5 screen/VNC capabilities.** Reserved channel-type names; design happens separately when needed.
- **Port-tunnel UI (REMOTE-4.x).** This design specifies *how* port-tunnel channels would slot into the SSH model (deferred channel-open via host UI prompt) but does not implement the prompt UI.
- **Pairing UX.** The existing pairing-code ceremony is unchanged; only the persisted key type swaps from X25519 to Ed25519.

## 3. Decisions summary

| Decision | Choice | Rationale (short) |
|---|---|---|
| Auth mechanism | SSH KEX + publickey userauth | Don't roll our own crypto; swift-nio-ssh is Apple-maintained, BSD/Apache, used in Apple's own infra |
| Channel multiplexing | SSH channels (RFC 4254) | Built-in window/flow control we currently lack; standardized custom-channel-type extension point |
| Terminal handshake | SSH session channel + `pty-req` | Standardized PTY semantics; deletes our first-frame `TerminalChannelOpenMeta` |
| Identity key type | Ed25519 | Required by SSH; existing X25519 keys have no surviving consumer once Noise is removed |
| Channel-open authorization | At-open hook via swift-nio-ssh, checks `TrustedPeer.capabilities` | Matches REMOTE-6.1 / 7.1 spec text |
| Reconnect | Full SSH KEX + userauth + channel re-open | Matches REMOTE-2.1; no SSH-level session resumption (would weaken the guarantee) |
| Revocation | `triggerUserInitiatedClose()` on active SSH connections + userauth lookup miss for future attempts | Matches REMOTE-3.1 |
| Migration | Straight cutover; no parallel-track feature flag | Designed-for behavior; flag would persist as tech debt |
| `/ws` retirement | Included in this delivery | M2a's terminal channel needs a production consumer to earn its keep |
| swift-nio-ssh dependency placement | `GrafttyHostAgent` (server) + `GrafttyMobileKit` (client), not `GrafttyKit` | Keeps `graftty-cli` out of the SSH dep tree, matching how PR #176 placed WebRTC |

## 4. Architecture overview

```
┌──────────────────────────────────────────────────────────────────┐
│  iOS app (GrafttyMobileKit; does NOT link GrafttyHostAgent)      │
│                                                                  │
│  RemoteHostConnection (existing actor; channel layer rewired)    │
│   └── RTCDataChannel (existing, stasel/WebRTC SDK)               │
│        └── SSHNIOTransport (new)  ─── adapts NIO ↔ DataChannel   │
│             └── NIOSSHClient (swift-nio-ssh)                     │
│                  ├── session channel + pty-req     → terminal    │
│                  ├── "panes-state@graftty.dev"     → state push  │
│                  └── "pane-control@graftty.dev"    → RPC         │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │  WebRTC DTLS-encrypted DataChannel
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Mac app (GrafttyKit + GrafttyHostAgent)                         │
│                                                                  │
│  WebRTCHostAgent (existing actor; channel layer rewired)         │
│   └── RTCDataChannel                                             │
│        └── SSHNIOTransport (new)                                 │
│             └── NIOSSHServer (swift-nio-ssh)                     │
│                  ├── session-channel handler → PtyProcess        │
│                  ├── "panes-state" handler   → PanesStateHandler │
│                  └── "pane-control" handler  → PaneControlHandler│
└──────────────────────────────────────────────────────────────────┘
```

The DataChannel is established via the existing M1.2 signaling path (`POST /v1/rtc/offer`). Once the DataChannel reports `open`, the SSH handshake begins. SSH KEX + userauth complete before any channel opens, so by the time application code reads or writes a channel, the peer is authenticated.

## 5. Module placement

| Module | Adds | Deletes |
|---|---|---|
| `GrafttyProtocol` | `SSHChannelTypes.swift` pinning `panes-state@graftty.dev` and `pane-control@graftty.dev` | `ChannelFrame.swift`, `ChannelID.swift`, `ChannelFrameCoder.swift`, `TerminalChannelOpenMeta.swift` |
| `GrafttyHostAgent` | `SSHNIOTransport`, `SSHServerSetup`, `SSHUserAuthDelegate`, `Channels/TerminalSessionHandler`, `Channels/PanesStateChannelHandler`, `Channels/PaneControlChannelHandler` | — |
| `GrafttyKit` | — (existing `PanesStateHandler`/`PaneControlHandler` business logic stays, factored out of `ChannelRouter` coupling) | `Remote/ChannelRouter.swift` |
| `GrafttyMobileKit` | `Remote/SSHNIOTransport`, `Remote/SSHClientSetup`, `Remote/Channels/TerminalSessionClient`, `Remote/Channels/PanesStateChannelClient`, `Remote/Channels/PaneControlChannelClient` | `Remote/ChannelRouter.swift`, `Session/WebSocketClient.swift` |
| `Package.swift` | `swift-nio-ssh` dep added to `GrafttyHostAgent` and `GrafttyMobileKit` targets | — |

The mirrored shape (`SSHNIOTransport` exists on both sides) follows the precedent of `ChannelRouter` — different OS targets, different platform-specific dependencies, intentional duplication of a small protocol-aware module.

## 6. Identity, pairing, key migration

### 6.1 Key type migration

The current identity stores persist X25519 keys for the Noise handshake. With Noise deleted, these keys have no surviving consumer. The migration:

| Type | Before | After |
|---|---|---|
| `HostIdentityStore` private key | `Curve25519.KeyAgreement.PrivateKey` (X25519) | `Curve25519.Signing.PrivateKey` (Ed25519 in CryptoKit naming) |
| `ClientIdentityStore` private key | same X25519 | same Ed25519 |
| `RemoteIdentityPublicKey` | 32 bytes, doc'd "X25519 static identity key" | 32 bytes, doc'd "Ed25519 verification key" |
| `RemoteIdentityFingerprint` | SHA-256 over canonical 32-byte pubkey | unchanged |
| On-disk JSON | `{"privateKeyData": "<32 bytes>"}` | `{"privateKeyData": "<32 bytes>"}` (same shape; bytes are Ed25519) |

The on-disk JSON shape is byte-identical between schemes (both keys are 32-byte raw representations); only the interpretation changes. The migration must invalidate existing on-disk keys because an X25519 key is not a valid Ed25519 seed.

**Migration impact:** existing dev/test pairings are invalidated, requiring a re-pair (one QR-code scan). Acceptable because no shipped release consumes the identity key — the only intended consumer (M1.3 Noise) was deferred and never landed.

**Detection strategy:** the persisted JSON schema gains an explicit `version` field. Records written by the new code carry `{"version": 2, "privateKeyData": "<base64 Ed25519 raw bytes>"}`. Legacy records (no `version` field, or `version != 2`) are treated as "no key persisted" — the loader ignores them and regenerates an Ed25519 key on next call. A bare byte-level check would not work: CryptoKit's `Curve25519.Signing.PrivateKey(rawRepresentation:)` accepts arbitrary 32-byte input (it treats any 32 bytes as a seed), so we cannot detect cross-scheme byte content by parse failure.

### 6.2 Mapping to SSH primitives

| Graftty type | SSH role |
|---|---|
| `HostIdentityStore` | SSH host key |
| `ClientIdentityStore` | Client's SSH publickey-auth key |
| `TrustedPeerStore` (on host) | `authorized_keys` analog; lookup at userauth time |
| `TrustedPeer.publicKey` | Client's Ed25519 SSH public key |
| `TrustedPeer.capabilities` | Application-layer authorization layered on SSH-authenticated identity |
| `PinnedHostStore` (on client) | `known_hosts` analog; host pubkey check at SSH KEX |
| `HostPairingServer` + `ClientPairingSession` | First-run pubkey exchange + UX confirmation. **Unchanged UX.** |
| `RemotePairingTranscript` | Pubkey exchange wire format. **Unchanged shape**, bytes are Ed25519. |
| `RemoteIdentityFingerprint.display` | SSH-style fingerprint display (8 groups of 8 hex chars) |

The pairing ceremony itself does not change — same QR code, same confirmation prompts, same `PairedDeviceCapabilities.defaultsAfterPairing`. The only difference is the bytes exchanged are Ed25519 public keys.

## 7. Session establishment

### 7.1 Sequence

```
iOS                                                Mac
  │                                                 │
  │── WebRTC signaling: POST /v1/rtc/offer ────────►│
  │◄── WebRTC signaling: answer ────────────────────│
  │                                                 │
  │── ICE connectivity checks ◄─────────────────────│
  │                                                 │
  │── RTCDataChannel "graftty-rtc" opens ◄──────────│
  │                                                 │
  │── SSH KEX (curve25519-sha256) ──────────────────►│
  │                                                 │
  │  client verifies host pubkey                    │
  │  against PinnedHostStore                        │
  │                                                 │
  │── SSH userauth publickey (Ed25519) ────────────►│
  │                                                 │
  │                       host looks up offered key │
  │                       in TrustedPeerStore       │
  │                                                 │
  │◄── SSH_MSG_USERAUTH_SUCCESS ────────────────────│
  │                                                 │
  │── SSH_MSG_CHANNEL_OPEN (session) ──────────────►│
  │── SSH "pty-req" + "shell" ─────────────────────►│
  │                                                 │
  │── SSH_MSG_CHANNEL_OPEN (panes-state@graftty.dev)►│
  │── SSH_MSG_CHANNEL_OPEN (pane-control@graftty.dev)►│
  │                                                 │
  │  ◄─── application traffic on channels ───►      │
```

### 7.2 Algorithm pinning (REMOTE-8.x)

| Layer | Pinned |
|---|---|
| KEX | `curve25519-sha256` only |
| Host key | `ssh-ed25519` only |
| User auth | `publickey` only (no `password`, no `keyboard-interactive`) |
| Cipher | `chacha20-poly1305@openssh.com`, `aes256-gcm@openssh.com` |
| MAC | implicit in AEAD ciphers |

Rejecting any other negotiation is the responsibility of `SSHServerSetup` (server side) and `SSHClientSetup` (client side). The corresponding `REMOTE-8.x` specs encode each pin as observable behavior.

### 7.3 Key-only identity

SSH userauth has the property that the username field and the offered public key are independent in the wire protocol. Graftty's identity model is **key-only**: `TrustedPeerStore` is keyed by `publicKey`, not by `(username, publicKey)`. The username field in incoming userauth requests is ignored. Clients send a fixed dummy username (convention: `graftty`).

This prevents a class of attacks where a peer presents a valid pubkey with a different claimed username trying to exercise different capabilities — under key-only lookup, the capability set is intrinsic to the identity.

## 8. Channel layer

### 8.1 The three SSH channel types

| SSH channel | Replaces | Purpose |
|---|---|---|
| Session channel + `pty-req` + `shell` | `TerminalChannelHandler` + `TerminalChannelOpenMeta` | Terminal I/O. One channel per attached PTY. iPad with N visible leaves runs N concurrent session channels. |
| `panes-state@graftty.dev` (custom type) | `PanesStateHandler` framing | Server pushes length-prefixed JSON `PanesStateMessage` envelopes. One channel per `RemoteHostConnection`. |
| `pane-control@graftty.dev` (custom type) | `PaneControlHandler` framing | Length-prefixed JSON request/response RPC. Concurrent RPCs ride the same channel; client serializes its own RPCs. One channel per connection. |

### 8.2 Framing within custom channels

Each application message on `panes-state@graftty.dev` or `pane-control@graftty.dev` is `<u32 BE length><JSON bytes>` over the SSH channel byte stream. The JSON envelopes are the same `PanesStateMessage` / `PaneControlRequest` / `PaneControlResponse` types from `GrafttyProtocol`; only the outer transport changes from M1.4 `ChannelFrame.payload` to SSH channel data.

### 8.3 Channel-open authorization

When a peer opens a channel, the server-side handler is invoked with the authenticated `TrustedPeer` (resolved during userauth). The handler checks `TrustedPeer.capabilities` before completing the open:

| Channel type | Required capability |
|---|---|
| Session channel (with `pty-req`) | `terminalControl == .allowed` |
| `panes-state@graftty.dev` | `terminalControl == .allowed` |
| `pane-control@graftty.dev` | `terminalControl == .allowed` |

Rejection sends `SSH_MSG_CHANNEL_OPEN_FAILURE` with reason `SSH_OPEN_ADMINISTRATIVELY_PROHIBITED`. The client surfaces this as a structured `CapabilityDenied` error to UI code.

### 8.4 Per-operation authorization (designed-for; not implemented)

`PairedDeviceCapabilities.portTunnel` has an `askEachTime` mode. Channel-open authorization is binary — it cannot pause for a host-side user prompt. The design accommodates this for future port-tunnel implementation:

When a port-tunnel channel-open arrives, the handler **defers** the open by enqueuing an approval request on the host UI thread, then suspending. The user confirms or denies via a host-side prompt. The handler resumes and completes the open or rejects it. swift-nio-ssh supports this via the channel-open `EventLoopPromise`.

This pattern is documented in the design so port-tunnel work (REMOTE-4.x) has a clear shape to land into. It is not implemented in this delivery — port-tunnel channels are not yet wired.

## 9. Reconnect and revocation

### 9.1 Reconnect (REMOTE-2.1)

When the `RTCPeerConnection` enters `.failed` or `.disconnected`, or the DataChannel closes:

1. The `RemoteHostConnection` (mobile) and `WebRTCHostAgent` (host) tear down the entire SSH state.
2. Open SSH channels close; pending RPCs on `pane-control@graftty.dev` resolve with synthetic error.
3. On next attach, a new `RTCPeerConnection` is built (fresh signaling) → new DataChannel → new `SSHNIOTransport` → **fresh SSH KEX and userauth**.
4. The client re-opens channels by name. Session channels are re-opened per-pane with the captured `sessionName` from the previous session.

No SSH-level session resumption is attempted. SSH does not natively support it; adding it would weaken the REMOTE-2.1 guarantee.

### 9.2 Revocation (REMOTE-3.1, REMOTE-7.6)

When a `TrustedPeer` is revoked on the host via `TrustedPeerStore`:

1. The host maintains a per-peer set of live SSH connections, indexed by `RemoteDeviceID`.
2. On revocation, each matching `NIOSSHHandler` has `triggerUserInitiatedClose()` invoked. swift-nio-ssh sends `SSH_MSG_DISCONNECT` with reason `SSH_DISCONNECT_AUTH_CANCELLED_BY_USER`, closing the SSH connection, which tears down the DataChannel.
3. Future userauth attempts from the revoked peer find no matching active `TrustedPeer` and respond with `SSH_MSG_USERAUTH_FAILURE`.

This satisfies both REMOTE-3.1 (all active secure channels close) and REMOTE-7.6 (pane_control channel closes specifically) with a single mechanism.

## 10. The `SSHNIOTransport` adapter

The one piece of new code without an obvious reference is `SSHNIOTransport` — the adapter between swift-nio-ssh's expected byte-stream `Channel` and the message-stream `RTCDataChannel` API. swift-nio-ssh assumes TCP-like ordered byte semantics; DataChannel delivers discrete messages.

### 10.1 Outbound (NIO → DataChannel)

swift-nio-ssh writes `ByteBuffer`s to the channel. `SSHNIOTransport` chunks these into DataChannel messages, respecting `RTCDataChannel`'s `maxPacketLifeTime: nil` reliable-ordered mode and the SCTP message size limit (16KB practical safe size). For SSH packets larger than the message size, multiple DataChannel sends are issued in order.

### 10.2 Inbound (DataChannel → NIO)

Incoming DataChannel messages are concatenated into a `ByteBuffer` and fed into the SSH state machine. SSH's own packet framing (length-prefixed packets per RFC 4253 §6) handles re-parsing; the adapter doesn't need to be aware of SSH packet boundaries.

### 10.3 Lifecycle

The adapter maps DataChannel state transitions onto NIO `Channel` events:

| DataChannel state | NIO event |
|---|---|
| `connecting` | `Channel` not yet active |
| `open` | `channelActive` fires |
| `closing` / `closed` | `channelInactive` fires; `Channel.close()` |
| error | `errorCaught` propagated, then close |

R2 (the first SSH PR) validates this adapter shape in a loopback test before any other SSH work commits to it.

## 11. Rollout plan

The 6-PR sequence. Each PR is independently shippable; the existing `/ws` path remains live until R6.

| PR | Scope | Wire state after | Risk |
|---|---|---|---|
| **R1** | Key migration: X25519 → Ed25519 in `HostIdentityStore` + `ClientIdentityStore` + doc comments on `RemoteIdentityPublicKey`. Existing dev pairings re-pair. | No SSH yet; nothing in production consumes the keys | Low |
| **R2** | Add `swift-nio-ssh` dep. Implement `SSHNIOTransport` (Mac + mobile). Loopback test: single-process `NIOSSHServer` ↔ `NIOSSHClient` over a `RTCDataChannel` pair with `exec ls` round-trip. | New code, not wired into production paths | Low — pure feature add |
| **R3** | `SSHUserAuthDelegate` (server) + `SSHServerSetup` + `SSHClientSetup` with `PinnedHostStore` host-key check. Loopback test: end-to-end publickey auth using existing identity stores. | Auth works end-to-end; no channels wired yet | Low |
| **R4** | `TerminalSessionHandler` (server) + `TerminalSessionClient` (mobile). `RemoteHostConnection` swapped from `ChannelRouter` to SSH for terminal. Terminal I/O round-trip test. iPhone still on `/ws`. | Two terminal paths coexist briefly (`/ws` + SSH session channel) | Medium — `RemoteHostConnection` API change |
| **R5** | `PanesStateChannelHandler` + `PaneControlChannelHandler` + their mobile clients. `PanesStateHandler` / `PaneControlHandler` business logic factored out of `ChannelRouter` coupling. Promote `REMOTE-6.1`, `REMOTE-7.1`, `REMOTE-7.6`. | All three channel types active over SSH | Medium |
| **R6** | Cut `/ws` over: iPhone `SessionClient` repointed at `TerminalSessionClient`. Delete `WebSocketClient`, `/ws` route, `ChannelRouter*`, `ChannelFrame*`, `ChannelID*`, `TerminalChannelOpenMeta*`. Promote `REMOTE-5.1`, `REMOTE-2.1`, `REMOTE-3.1`. | `/ws` gone; `ChannelRouter` family deleted | Medium-high — TestFlight gate required |

### 11.1 Decision gate at R2

R2 validates the `SSHNIOTransport` adapter. If swift-nio-ssh's `Channel` abstraction does not adapt cleanly to message-stream `RTCDataChannel`, R2's first fallback is a length-prefixed stream layer beneath SSH. If even that does not work, the architectural approach collapses and the rollout reverts to the M1.3 Noise plan. **R2 must demonstrate a clean `exec` round-trip before R3 commits.**

### 11.2 Why R6 carries TestFlight gate

R6 deletes `/ws`, cutting iPhone's current production transport. Mitigation: TestFlight ride before App Store submit. Roll-back plan: revert R6 alone; R1-R5 are independently shippable and do not affect production paths.

## 12. Spec ID transitions

| Spec ID | Current state | After this delivery |
|---|---|---|
| `REMOTE-1.1` (host identity persistence) | Active, X25519 | Active, EARS text unchanged; doc/code now Ed25519 |
| `REMOTE-1.2` (pairing verification code) | Active | Active, unchanged |
| `REMOTE-2.1` (reconnect re-auth) | Disabled inventory | **Promoted** — fresh SSH KEX + userauth on each reconnect |
| `REMOTE-3.1` (revocation tears down) | Disabled inventory | **Promoted** — `triggerUserInitiatedClose()` on revocation |
| `REMOTE-4.1` / `4.2` (port tunnel policy) | Disabled inventory | Stays disabled — port-tunnel channels not in this delivery |
| `REMOTE-5.1` (`/ws` retired) | Disabled inventory | **Promoted** — `/ws` route deleted, iPhone uses SSH session channel |
| `REMOTE-6.1` (panes_state capability check) | Disabled inventory | **Promoted** — channel-open authorizer enforces |
| `REMOTE-6.2 / 6.3 / 6.4` (snapshot push) | Active per PR #176 | Active, unchanged |
| `REMOTE-7.1` (pane_control capability check) | Disabled inventory | **Promoted** — channel-open authorizer enforces |
| `REMOTE-7.2` (split RPC behavior) | Active per PR #176 | Active, unchanged |
| `REMOTE-7.3 / 7.4 / 7.5` (close / conflict / focus) | Active per PR #177 | Active, unchanged |
| `REMOTE-7.6` (revocation closes pane_control channel) | Disabled inventory | **Promoted** — same mechanism as REMOTE-3.1 |

### 12.1 New REMOTE-8.x family — SSH session layer

| Spec | EARS text |
|---|---|
| **REMOTE-8.1** | When the host accepts a remote attach, the host shall negotiate SSH KEX restricted to `curve25519-sha256` and reject any other KEX proposal. |
| **REMOTE-8.2** | When the host receives a userauth request, the host shall accept only the `publickey` method and reject `password` and `keyboard-interactive` immediately. |
| **REMOTE-8.3** | When the host receives a userauth request, the host shall identify the peer solely by the offered public key against `TrustedPeerStore` and shall ignore the username field. |
| **REMOTE-8.4** | When the client receives a host key during SSH KEX, the client shall verify the key against `PinnedHostStore` and abort the connection on mismatch. |
| **REMOTE-8.5** | While accepting a remote attach, the host shall restrict its SSH cipher allowlist to `chacha20-poly1305@openssh.com` and `aes256-gcm@openssh.com`. |

These land in `Tests/GrafttyTests/Specs/RemoteTodo.swift` as disabled inventory in R1 and promote to active tests as their implementations land in R3.

## 13. Testing strategy

### 13.1 Loopback tests

Extend the M1.1 single-process pattern: paired `RTCPeerConnection` + `RTCDataChannel` running `NIOSSHServer` and `NIOSSHClient` on either end. Each PR in the rollout adds the loopback test for its layer (transport → userauth → terminal channel → custom channels).

### 13.2 Security regressions

For every reconnect path (ICE restart, DataChannel recreation, app foreground, host wake):

- Unpaired client cannot complete SSH userauth.
- Revoked peer's existing channels close within one tick; subsequent userauth fails.
- Channel-open without `terminalControl == .allowed` returns `SSH_OPEN_ADMINISTRATIVELY_PROHIBITED`.
- Modified host pubkey fails `PinnedHostStore` check on the client and aborts.
- Non-`publickey` userauth methods rejected immediately.
- KEX proposal of non-`curve25519-sha256` algorithm rejected.

No mocking of WebRTC or swift-nio-ssh primitives — real `RTCPeerConnection` pairs on loopback, real SSH transcripts, so algorithm pinning is exercised end-to-end.

### 13.3 Cross-repo contract tests

Existing tests in `Tests/GrafttyProtocolTests/` for `PanesStateMessage`, `PaneControlRequest`, `PaneControlResponse` round-trips stay relevant — they validate the JSON envelopes which are unchanged. New length-prefixed framing tests verify `<u32 BE length><JSON>` round-trips for SSH custom-channel framing.

### 13.4 Migration tests

R1 adds a unit test that simulates upgrading from "stored X25519 32-byte key" to the Ed25519 store: load-after-migration regenerates rather than crashing on key-type-mismatch.

### 13.5 Real-device gate at R6

The corporate-locked-down-network scenario is the actual product value of WebRTC. R6 requires real-network testing before the `/ws` cutover: TestFlight ride before App Store submit, plus manual verification on at least one corporate-network environment.

### 13.6 macOS `swift test` is insufficient for mobile code

Per the recorded constraint (`feedback_macos_swift_test_misses_uikit_guarded_code`), `swift test` on Mac false-greens UIKit-guarded code. Every PR in the rollout that touches `GrafttyMobileKit` requires iOS CI green before merge, not just Mac-side `swift test`.

## 14. Risks

1. **`SSHNIOTransport` adapter complexity.** swift-nio-ssh expects byte-stream semantics; `RTCDataChannel` is message-stream. R2 validates the adapter; if it doesn't work, fallback is a length-prefixed stream layer beneath SSH. If even that fails, the architectural approach collapses and rollout reverts to M1.3 Noise. R2 is the decision gate.
2. **WebRTC throughput ceiling (~30 Mbps per Coder's measurement).** Fine for terminal I/O. Limits Phase 5 capability scope. Out of scope here; flagged for future design.
3. **WebRTC lifecycle complexity.** PRs #181, #190, #194 evidence subtle ordering bugs in the DataChannel lifecycle. SSH adds another lifecycle layer (KEX → userauth → channel-open). New bug surface, mitigated by per-PR loopback tests.
4. **R6 production risk.** Deleting `/ws` cuts iPhone's current production transport. Mitigated by TestFlight gate; revertable in isolation.
5. **swift-nio-ssh pre-1.0 API stability.** Currently 0.13.0. Apple uses it internally and cadence is steady, but minor-version API breaks possible. Pin to specific minor in `Package.swift`; review on each bump.
6. **App Store review.** No new review surface vs existing WebRTC adoption. swift-nio-ssh is pure Swift, no new entitlements, no new linked frameworks.

## 15. Open questions

1. **Cipher allowlist breadth (REMOTE-8.5).** Strict: `chacha20-poly1305@openssh.com` + `aes256-gcm@openssh.com` only. Adding `aes128-gcm@openssh.com` may help older hardware AES-NI paths. Defer to R3; pick strictest set that real-device tests pass with.
2. **Keepalive cadence.** swift-nio-ssh supports SSH-level keepalive via `keepalive@openssh.com` global requests. WebRTC DataChannel has its own SCTP heartbeat; SSH keepalive on top may be redundant. Defer to R4.
3. **Soft cap on concurrent terminal channels per connection.** iPad M8 `MobileSurfaceBudget` caps live surfaces at 8 → up to 8 concurrent SSH session channels per host. Profile in R4 with all 8 active; revisit if a problem surfaces.
4. **`pane-control` RPC concurrency.** Current design: serialized RPCs on one long-lived channel. Alternative: channel-per-RPC. Stick with single channel + serialized RPCs matching current M4 model; revisit if a real concurrency need surfaces.
5. **Port-tunnel approval UX.** Designed-for shape in §8.4 (deferred channel-open). Concrete UI lands in a separate design alongside REMOTE-4.x implementation.

## 16. Decisions summary

| Topic | Decision |
|---|---|
| Auth | SSH KEX + publickey userauth via swift-nio-ssh |
| Multiplexing | SSH channels (RFC 4254) |
| Channel types | session+`pty-req`, `panes-state@graftty.dev`, `pane-control@graftty.dev` |
| Identity key | Ed25519 (migrated from X25519) |
| Username | Ignored at userauth; key-only identity |
| Algorithms | `curve25519-sha256` KEX; `ssh-ed25519` host key; `publickey` auth; AEAD ciphers |
| Channel auth | At-open hook checks `TrustedPeer.capabilities` |
| Reconnect | Full SSH re-handshake (no resumption) |
| Revocation | `triggerUserInitiatedClose()` + future-auth lookup miss |
| `/ws` retirement | Included in this delivery (R6) |
| Migration shape | Straight cutover; no feature flag |
| Rollout | 6 sequential PRs (R1–R6), R2 is the architecture decision gate |
