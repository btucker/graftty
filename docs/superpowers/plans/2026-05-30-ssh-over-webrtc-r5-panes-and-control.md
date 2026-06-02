# SSH-over-WebRTC R5 — `panes-state` + `pane-control` Channels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the two remaining custom SSH channel types (`panes-state@graftty.dev` and `pane-control@graftty.dev`) and rewire the iPad's `WorktreePanesStore` + `PaneControlClient` from the (never-wired) `ChannelRouter` framing to real SSH channels. Promote `REMOTE-6.1`, `REMOTE-7.1`, `REMOTE-7.6`.

**Architecture:**
- **Server-side:** add two new NIO `ChannelInboundHandler`s (`PanesStateChannelHandler`, `PaneControlChannelHandler`) that consume `<u32 BE length><JSON>` length-prefixed framing on the SSH child channel. Each handler takes a typed callback init parameter (`Subscribe` / `Mutator`) — the production callbacks are written for the first time in this PR, bridging `WorktreeMonitor` change events and `AppState` splittree mutations into the channel layer. `WebRTCHostAgent`'s `inboundChildChannelInitializer` grows from "session-only" to a multi-channel-type dispatch.
- **Client-side:** add two new types (`PanesStateChannelClient`, `PaneControlChannelClient`) that open the matching SSH channels and decode/encode the JSON envelopes. The existing `WorktreePanesStore` and `PaneControlClient` keep their *public* surface (`subscribe`, `current`, `split/close/swap`) but their internals get rewritten — `init(router:)` becomes `init(channelClient:)`. `RemoteHostConnection` gains two new openers symmetric to R4's `openTerminalSession`.
- **Capability gate:** R5's REMOTE-6.1/7.1/7.6 are all gated by the same capability (`PairedDeviceCapabilities.terminalControl == .allowed`). To avoid an over-engineered per-channel `AuthenticatedPeerBox`, the check moves up into `SSHUserAuthDelegate` — a peer without `terminalControl: .allowed` can never authenticate, which trivially closes the channel-open gates by exclusion. A future port-tunnel PR (REMOTE-4.x, indefinitely deferred) introduces per-channel-open peer inspection when it actually needs it.
- **Deletions:** the unwired-from-production `PanesStateHandler` / `PaneControlHandler` (host-side, `GrafttyKit/Remote/`) and `TerminalChannelClient` (mobile-side, replaced by R4's `TerminalSessionClient`) and the mobile-side `ChannelRouter.swift` get deleted. Host-side `ChannelRouter*`/`ChannelFrame*`/`ChannelID*` stay until R6 per parent design §11.

**Tech Stack:** Swift 5.10+, swift-nio 2.x, swift-nio-ssh 0.13, WebRTC (stasel/WebRTC SDK), Swift Testing + XCTest.

**Parent design:** [`2026-05-21-ssh-over-webrtc-design.md`](../specs/2026-05-21-ssh-over-webrtc-design.md) — see §5 (module placement), §8 (channel layer), §11 row R5, §12 (spec transitions including new REMOTE-8.x family).

---

## File Structure

**Create:**
- `Sources/GrafttyProtocol/SSHChannelTypes.swift` — two `String` constants pinning the wire channel type names; single source of truth shared by client + server.
- `Sources/GrafttyHostAgent/SSH/Channels/PanesStateChannelHandler.swift` — server-side NIO handler.
- `Sources/GrafttyHostAgent/SSH/Channels/PaneControlChannelHandler.swift` — server-side NIO handler.
- `Sources/GrafttyMobileKit/Remote/SSH/Channels/PanesStateChannelClient.swift` — mobile-side opener + decoder.
- `Sources/GrafttyMobileKit/Remote/SSH/Channels/PaneControlChannelClient.swift` — mobile-side opener + RPC.
- `Sources/GrafttyHostAgent/SSH/Channels/LengthPrefixedFraming.swift` — small helper exposing `LengthFieldBasedFrameDecoder(lengthFieldLength: .four)` + `LengthFieldPrepender(lengthFieldLength: .four)` constructors used by both new server-side channel handlers. (Mobile side gets a `#if canImport(UIKit)` mirror at `GrafttyMobileKit/Remote/SSH/Channels/LengthPrefixedFraming.swift` — same precedent as the `SSHNIOTransport` duplication.)
- `Sources/GrafttyMobileKit/Remote/SSH/Channels/LengthPrefixedFraming.swift` — mirror of the above for the mobile-side pipeline.
- `Tests/GrafttyTests/Remote/SSH/PanesStateChannelHandlerTests.swift` — Mac-runnable `EmbeddedChannel` tests; the new home for `@spec REMOTE-6.2`, `REMOTE-6.3`, `REMOTE-6.4`.
- `Tests/GrafttyTests/Remote/SSH/PaneControlChannelHandlerTests.swift` — Mac-runnable `EmbeddedChannel` tests; the new home for `@spec REMOTE-7.2`, `REMOTE-7.3`, `REMOTE-7.4`, `REMOTE-7.5`.
- `Tests/GrafttyMobileKitTests/Remote/SSH/SSHPanesAndControlLoopbackTests.swift` — iOS-only end-to-end loopback covering both new channel types over a real `RTCPeerConnection` pair + real SSH stack.

**Modify:**
- `Sources/GrafttyHostAgent/SSH/SSHUserAuthDelegate.swift` — store now returns the resolved `TrustedPeer`; check `terminalControl == .allowed` before succeeding.
- `Sources/GrafttyHostAgent/WebRTCHostAgent.swift` — accept two new init parameters (`panesStateSubscribe`, `paneControlMutator`); expand `inboundChildChannelInitializer` to dispatch by `SSHChannelType` (`.session` → R4's `TerminalSessionHandler`; `.unknown(panesStateChannelType)` → new `PanesStateChannelHandler`; `.unknown(paneControlChannelType)` → new `PaneControlChannelHandler`).
- `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift` — add `openPanesStateChannel()` and `openPaneControlChannel()` symmetric to R4's `openTerminalSession`.
- `Sources/GrafttyMobileKit/Remote/WorktreePanesStore.swift` — rewrite internals: drop `router: ChannelRouter` constructor parameter; new constructor takes a `PanesStateChannelClient`. Public method signatures unchanged.
- `Sources/GrafttyMobileKit/Remote/PaneControlClient.swift` — same: drop `router: ChannelRouter`; new constructor takes a `PaneControlChannelClient`. Public method signatures unchanged.
- `Sources/Graftty/GrafttyApp.swift` — pass the new `panesStateSubscribe` and `paneControlMutator` closures when constructing `WebRTCHostAgent`. `panesStateSubscribe` bridges the existing `WorktreeMonitor` change pipeline; `paneControlMutator` dispatches to existing splittree mutations on `MainActor`.
- `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift` — supply the iPad path with `WorktreePanesStore` + `PaneControlClient` instances built from the per-host `RemoteHostConnection`. iPhone (no `RemoteHostConnection`) sees the same surface but with no-op/idle stores.
- `Sources/GrafttyMobileKit/App/RootView.swift` — wire the new env-supplied stores into the views that already consume `WorktreePanesStore` and `PaneControlClient`.
- `Tests/GrafttyTests/Specs/RemoteTodo.swift` — remove the `@Test(.disabled)` inventory entries for `REMOTE-6.1`, `REMOTE-7.1`, `REMOTE-7.6` (now active).
- `Tests/GrafttyKitTests/Remote/PanesStateHandlerTests.swift` — **delete this file** (replaced by `PanesStateChannelHandlerTests.swift` under `Tests/GrafttyTests/Remote/SSH/`).
- `Tests/GrafttyKitTests/Remote/PaneControlHandlerTests.swift` — **delete this file** (replaced).
- `Tests/GrafttyMobileKitTests/Remote/WorktreePanesStoreTests.swift` — update constructor calls to use the new `PanesStateChannelClient`-based init; the test bodies (which exercise the public API) carry over.
- `Tests/GrafttyMobileKitTests/Remote/PaneControlClientTests.swift` — same.

**Delete:**
- `Sources/GrafttyKit/Remote/PanesStateHandler.swift` — unwired-in-production; logic re-expressed in the new NIO handler.
- `Sources/GrafttyKit/Remote/PaneControlHandler.swift` — same.
- `Sources/GrafttyMobileKit/Remote/ChannelRouter.swift` — mobile-side router; its only consumers are the three files we're rewriting / deleting in this PR.
- `Sources/GrafttyMobileKit/Remote/TerminalChannelClient.swift` — R4's `TerminalSessionClient` already replaced this; nothing wires it anymore.

(The shared `Sources/GrafttyKit/Remote/ChannelRouter.swift`, `ChannelFrame.swift`, `ChannelID.swift`, `ChannelFrameCoder.swift`, `TerminalChannelOpenMeta.swift`, and `Sources/GrafttyProtocol/PaneControlEnvelope.swift` etc. stay until R6 per parent design §11. After R5 they have zero non-test consumers in `Sources/`, but R6 already owns the deletion sweep.)

---

## Important Context for the Implementer

### Wire format inside the custom channels

Each application message is `<u32 BE length><JSON>` over the SSH channel byte stream — parent design §8.2. swift-nio ships `LengthFieldBasedFrameDecoder` and `LengthFieldPrepender` exactly for this; install them in the SSH child channel's pipeline *before* the application handler. After the framing handlers, the application handler sees one `ByteBuffer` per JSON message — no boundary handling required.

### How R4 wires SSH channels

R4 already established the pattern. In `Sources/GrafttyHostAgent/WebRTCHostAgent.swift:218`:

```swift
inboundChildChannelInitializer: { child, channelType in
    guard case .session = channelType else {
        return child.eventLoop.makeFailedFuture(WebRTCHostAgentError.unsupportedChannelType)
    }
    return child.eventLoop.makeCompletedFuture {
        let sessionHandler = TerminalSessionHandler(streamFactory: factory)
        try child.pipeline.syncOperations.addHandler(sessionHandler)
    }
}
```

R5 expands the switch — `case .session` stays; two new `case .unknown(let name) where ...` clauses route to the new handlers (with the framing handlers spliced in first).

### `SSHChannelType.unknown` is exactly the wire-string custom channel type

swift-nio-ssh represents non-built-in channel-open types as `.unknown(String)`. When an iPad client sends `SSH_MSG_CHANNEL_OPEN` with channel type `panes-state@graftty.dev`, the server-side `inboundChildChannelInitializer` is invoked with `channelType == .unknown("panes-state@graftty.dev")`. There's no custom handshake to negotiate — the channel type *is* the string.

### Mobile-side channel open via `NIOSSHHandler.createChannel`

R4's `TerminalSessionClient.connect()` already demonstrates the pattern (`Sources/GrafttyMobileKit/Remote/SSH/Channels/TerminalSessionClient.swift`):

```swift
let promise = parentChannel.eventLoop.makePromise(of: Channel.self)
parentHandler.createChannel(promise, channelType: .session) { child, _ in
    return child.pipeline.addHandler(InboundRelay(owner: self))
}
```

For custom channel types, pass `.unknown(SSHChannelTypeNames.panesState)` (or `.paneControl`) instead of `.session`.

### Subscribe + Mutator typealiases stay; their implementations are new

The `PanesStateHandler.Subscribe` and `PaneControlHandler.Mutator` typealiases on the *old* handlers express the right shapes. R5 keeps the typealias signatures (re-exported on the new handler types) and writes the production implementations from scratch in `GrafttyApp.swift`:

- **`Subscribe`:** `@Sendable (@escaping @Sendable ([WorktreePanes]) async -> Void) async -> Cancellable`. Production bridges `WorktreeMonitor` change events (same pipeline the desktop sidebar consumes) into the channel's `onChange` callback; first call fires immediately with the current snapshot. The existing `setWorktreePanesProvider` closure in `GrafttyApp.swift` (built around line 1195) computes a snapshot from `AppState` on `MainActor` — that snapshot-builder is the reusable piece. R5 wires it to a *change*-driven loop instead of `/ws`'s poll-driven `worktreePanesProvider`.
- **`Mutator`:** `@Sendable (PaneControlRequest) async -> PaneControlResponse`. Production dispatches each variant to existing splittree mutations on `MainActor` and returns `.ok` / `.error(...)` based on success.

### Where the existing tests for these handlers live

| Old test | Status after R5 | Replacement |
|---|---|---|
| `Tests/GrafttyKitTests/Remote/PanesStateHandlerTests.swift` | Deleted | `Tests/GrafttyTests/Remote/SSH/PanesStateChannelHandlerTests.swift` (new home) |
| `Tests/GrafttyKitTests/Remote/PaneControlHandlerTests.swift` | Deleted | `Tests/GrafttyTests/Remote/SSH/PaneControlChannelHandlerTests.swift` (new home) |
| `Tests/GrafttyMobileKitTests/Remote/WorktreePanesStoreTests.swift` | Modified | Same file; constructor calls updated |
| `Tests/GrafttyMobileKitTests/Remote/PaneControlClientTests.swift` | Modified | Same file; constructor calls updated |

The new handler-test homes (`Tests/GrafttyTests/Remote/SSH/`) follow R4's precedent — XCTest, `EmbeddedChannel`-based, in the `GrafttyTests` target so the `GrafttyHostAgent` types are reachable via `Graftty`'s transitive dep.

### Loopback test reuses R4's pattern

`Tests/GrafttyMobileKitTests/Remote/SSH/SSHTerminalLoopbackTests.swift` (R4) extracts `LoopbackPeer`, `InMemoryTrustedPeerSet`, `fingerprint(of:)`, and the `runTerminalLoopback(...)` driver. R5 copies these (per R3→R4 precedent: "copy, don't extract until R6") into the new `SSHPanesAndControlLoopbackTests.swift`. The R5 loopback differs only in:
- the streamFactory becomes a `panesStateSubscribe` + `paneControlMutator` pair (with fakes)
- the client opens `.unknown(panesStateChannelType)` and `.unknown(paneControlChannelType)` instead of `.session`
- assertions verify the JSON envelopes round-trip via length-prefixed framing

### Capability check semantics

Parent design §8.3 lists all three R5-scope channel types as requiring `terminalControl == .allowed`. By checking at userauth time:
- Peers with `.allowed` authenticate; all subsequent channel opens succeed.
- Peers without `.allowed` see `SSH_MSG_USERAUTH_FAILURE`; no channels can open.

REMOTE-6.1 / 7.1 phrase the requirement as "shall accept the channel...for any trusted peer holding the terminal_control capability." Checking at userauth time satisfies this — the observable behavior for paired peers with `.allowed` is unchanged; the behavior for peers without is "connection refused at userauth" instead of "channel-open refused." No spec text pins the SSH wire error type.

REMOTE-7.6 says revocation closes any open `pane_control` channel. R3 already provides `triggerUserInitiatedClose()` plumbing per parent §9.2. R5 wires the revocation hook in the host app — when `TrustedPeerStore` removes a peer, all SSH connections for that peer get torn down (which closes every channel including `pane_control`).

---

## Task 1: `SSHChannelTypes.swift` — pin the wire-strings in `GrafttyProtocol`

**Files:**
- Create: `Sources/GrafttyProtocol/SSHChannelTypes.swift`

A 10-line constants file. Single source of truth so server-side and client-side code can't drift on the wire string.

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Wire-string identifiers for graftty's custom SSH channel types. These
/// strings are sent in `SSH_MSG_CHANNEL_OPEN` payloads and arrive on the
/// server side as `SSHChannelType.unknown(String)` per swift-nio-ssh.
///
/// The `@graftty.dev` suffix follows RFC 4254 §5.1's vendor-extension
/// convention; the channel types are namespaced and will not collide with
/// stock OpenSSH or other SSH libraries.
public enum SSHChannelTypeNames {
    /// Server-pushed snapshots of `[WorktreePanes]`. One channel per
    /// `RemoteHostConnection`.
    public static let panesState = "panes-state@graftty.dev"

    /// Client→server RPC for splittree mutations (`split`, `close`,
    /// `swap`). One channel per connection; RPCs serialised by the client.
    public static let paneControl = "pane-control@graftty.dev"
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target GrafttyProtocol`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyProtocol/SSHChannelTypes.swift
git commit -m "$(cat <<'EOF'
feat(R5): SSHChannelTypeNames — pin custom SSH channel type wire strings

GrafttyProtocol single source of truth for "panes-state@graftty.dev" and
"pane-control@graftty.dev". Server-side dispatch reads these from
SSHChannelType.unknown(...); mobile-side passes them to
NIOSSHHandler.createChannel(channelType: .unknown(...)).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `SSHUserAuthDelegate` — capability check at userauth time

**Files:**
- Modify: `Sources/GrafttyHostAgent/SSH/SSHUserAuthDelegate.swift`

Currently `SSHUserAuthDelegate.requestReceived` does `try store.get(fingerprint:) != nil` and discards the peer. R5 changes this to also gate on `terminalControl`. The change is the minimum required to enforce REMOTE-6.1/7.1/7.6 against R5's three channel types; future port-tunnel work introduces per-channel-open peer inspection separately.

- [ ] **Step 1: Locate the userauth resolution block**

Open `Sources/GrafttyHostAgent/SSH/SSHUserAuthDelegate.swift`. The `.publicKey` branch of `requestReceived` currently reads:

```swift
case .publicKey(let publicKeyRequest):
    do {
        let fingerprint = try Self.fingerprint(of: publicKeyRequest.publicKey)
        if try store.get(fingerprint: fingerprint) != nil {
            responsePromise.succeed(.success)
        } else {
            responsePromise.succeed(.failure)
        }
    } catch {
        responsePromise.succeed(.failure)
    }
```

- [ ] **Step 2: Replace with the cap-gated version**

```swift
case .publicKey(let publicKeyRequest):
    do {
        let fingerprint = try Self.fingerprint(of: publicKeyRequest.publicKey)
        if let peer = try store.get(fingerprint: fingerprint),
           peer.capabilities.terminalControl == .allowed {
            responsePromise.succeed(.success)
        } else {
            // Either no matching trusted peer (unpaired / revoked) or the
            // peer's terminalControl capability has been disabled. Reject
            // with the same SSH_MSG_USERAUTH_FAILURE — clients can't tell
            // the difference, which prevents probing for revoked-vs-unpaired
            // status. REMOTE-6.1 / REMOTE-7.1 are satisfied by exclusion:
            // a peer that can't authenticate can't open any channel.
            responsePromise.succeed(.failure)
        }
    } catch {
        responsePromise.succeed(.failure)
    }
```

Notice the change is *additive within the boolean*: the existing `!= nil` lookup just becomes `if let peer, peer.capabilities.terminalControl == .allowed`.

- [ ] **Step 3: Update the `@spec` comment block on the type to reflect the new behavior**

Replace the existing doc block above `public struct SSHUserAuthDelegate` (currently `@spec REMOTE-8.2` / `@spec REMOTE-8.3`) with:

```swift
/// @spec REMOTE-8.2
/// @spec REMOTE-8.3
/// @spec REMOTE-6.1
/// @spec REMOTE-7.1
/// Server-side userauth delegate that backs SSH authentication against
/// graftty's `TrustedPeerStore`. Identity is key-only — the SSH
/// userauth `username` field is deliberately ignored; the peer is
/// resolved entirely by the offered Ed25519 public key.
///
/// REMOTE-6.1 / REMOTE-7.1 capability enforcement happens here, not at
/// channel-open: all R5-scope channel types (session/pty, panes-state,
/// pane-control) require the same `terminalControl == .allowed`
/// capability, so a peer without it cannot authenticate at all.
/// SSH_MSG_USERAUTH_FAILURE closes every R5 channel-open gate by
/// exclusion. When per-channel capability differentiation actually
/// matters (port-tunnel REMOTE-4.x with `askEachTime`), that PR will
/// introduce a per-connection `AuthenticatedPeerBox` and migrate the
/// check to channel-open time.
```

- [ ] **Step 4: Write a new test for the capability gate**

Create `Tests/GrafttyTests/Remote/SSH/SSHUserAuthCapabilityTests.swift` (new file; XCTest like the rest of `GrafttyTests`).

```swift
import CryptoKit
import GrafttyHostAgent
import GrafttyKit
import NIO
import NIOEmbedded
import NIOSSH
import XCTest

/// Tests for the capability check folded into `SSHUserAuthDelegate` per
/// R5's REMOTE-6.1/7.1 enforcement strategy.
final class SSHUserAuthCapabilityTests: XCTestCase {

    /// @spec REMOTE-6.1: A trusted peer with `terminalControl: .allowed`
    /// authenticates successfully.
    func testTrustedPeerWithCapAuthenticates() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let store = makeStore()
        try store.upsert(makePeer(key: key, terminalControl: .allowed))

        let outcome = try await runUserAuth(key: key, store: store)
        XCTAssertEqual(outcome, .success)
    }

    /// @spec REMOTE-6.1: A trusted peer with `terminalControl: .disabled`
    /// is rejected at userauth time.
    func testTrustedPeerWithoutCapRejected() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let store = makeStore()
        try store.upsert(makePeer(key: key, terminalControl: .disabled))

        let outcome = try await runUserAuth(key: key, store: store)
        XCTAssertEqual(outcome, .failure)
    }

    /// An unpaired key fails userauth (existing R3 behavior, preserved).
    func testUnpairedKeyRejected() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let store = makeStore()
        // No upsert — store is empty.

        let outcome = try await runUserAuth(key: key, store: store)
        XCTAssertEqual(outcome, .failure)
    }

    // MARK: - helpers

    private func makeStore() -> TrustedPeerStore {
        TrustedPeerStore(directoryURL: tempDir())
    }

    private func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-r5-userauth-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePeer(
        key: Curve25519.Signing.PrivateKey,
        terminalControl: PairedDeviceCapabilities.TerminalControl
    ) -> TrustedPeer {
        let publicKey = try! RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        return TrustedPeer(
            id: RemoteDeviceID(UUID().uuidString),
            kind: .iPhone,
            publicKey: publicKey,
            displayName: "test",
            capabilities: PairedDeviceCapabilities(
                terminalControl: terminalControl,
                portTunnel: .disabled,
                screenView: .disabled,
                screenControl: .disabled
            ),
            pairedAt: Date(),
            lastSeenAt: nil
        )
    }

    /// Runs a single userauth roundtrip against an EmbeddedChannel-hosted
    /// `SSHUserAuthDelegate` and returns the resulting outcome.
    private func runUserAuth(
        key: Curve25519.Signing.PrivateKey,
        store: TrustedPeerStore
    ) async throws -> NIOSSHUserAuthenticationOutcome {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let delegate = SSHUserAuthDelegate(store: store)
        let publicKey = NIOSSHPublicKey(ed25519Key: key.publicKey)
        let request = NIOSSHUserAuthenticationRequest(
            username: "graftty",
            serviceName: "ssh-connection",
            request: .publicKey(.init(publicKey: publicKey))
        )
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOutcome.self)
        delegate.requestReceived(request: request, responsePromise: promise)
        return try await promise.futureResult.get()
    }
}
```

- [ ] **Step 5: Run the tests; expect them to pass once Step 2 is applied**

Run: `swift test --filter SSHUserAuthCapabilityTests`
Expected: 3 passes.

If the "without cap rejected" test fails (i.e., the modified delegate is still letting through `.disabled` peers), revisit Step 2.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyHostAgent/SSH/SSHUserAuthDelegate.swift \
        Tests/GrafttyTests/Remote/SSH/SSHUserAuthCapabilityTests.swift
git commit -m "$(cat <<'EOF'
feat(R5): SSHUserAuthDelegate gates on terminalControl capability

REMOTE-6.1 / REMOTE-7.1 / REMOTE-7.6 (R5 scope): all three new channel
types require the same `terminalControl == .allowed` capability. Rather
than build an AuthenticatedPeerBox to plumb the resolved TrustedPeer
from userauth down to the channel-open hook, just check at userauth time
- peers without the capability fail userauth and can never open any
channel. Closes REMOTE-6.1/7.1 by exclusion; equivalent observable
behavior for paired peers.

Per-channel-open peer inspection will be needed if/when port-tunnel
(REMOTE-4.x, deferred) lands its `askEachTime` mode; that PR introduces
the box at the time it's actually needed. Until then this is YAGNI.

3 XCTest cases against an EmbeddedChannel-hosted delegate cover the
trusted-with-cap, trusted-without-cap, and unpaired paths.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `PanesStateChannelHandler` (server-side) + tests

**Files:**
- Create: `Sources/GrafttyHostAgent/SSH/Channels/PanesStateChannelHandler.swift`
- Create: `Sources/GrafttyHostAgent/SSH/Channels/LengthPrefixedFraming.swift`
- Create: `Tests/GrafttyTests/Remote/SSH/PanesStateChannelHandlerTests.swift`

The handler installs *after* `LengthFieldBasedFrameDecoder` + `LengthFieldPrepender` so it sees one `ByteBuffer` per JSON message and writes one buffer per outbound JSON. On `channelActive` it calls `subscribe(_:)`; the supplied closure fires once with the initial snapshot and again on every change. Each fire encodes the snapshot as `PanesStateMessage.snapshot(...)` and writes it length-prefixed back to the SSH channel.

- [ ] **Step 1: Create the framing helper**

Create `Sources/GrafttyHostAgent/SSH/Channels/LengthPrefixedFraming.swift`:

```swift
import NIOCore
import NIOExtras

/// Length-prefixed framing helpers for graftty's custom SSH channels.
/// Each application message on `panes-state@graftty.dev` and
/// `pane-control@graftty.dev` is `<u32 BE length><JSON>` over the SSH
/// channel byte stream (parent design §8.2).
///
/// `NIOExtras` ships exactly the codecs we need; this file just names
/// the configured constructors so both the server-side and the
/// mobile-side mirror agree on the same field width (4 bytes, big-endian).
public enum LengthPrefixedFraming {
    /// Decode `<u32 BE length><payload>` into one `ByteBuffer` per
    /// payload. Wrap in `ByteToMessageHandler` when installing.
    public static func makeFrameDecoder() -> ByteToMessageHandler<LengthFieldBasedFrameDecoder> {
        ByteToMessageHandler(LengthFieldBasedFrameDecoder(lengthFieldLength: .four))
    }

    /// Prepend `<u32 BE length>` to each outbound `ByteBuffer`. Wrap in
    /// `MessageToByteHandler` when installing.
    public static func makeFramePrepender() -> MessageToByteHandler<LengthFieldPrepender> {
        MessageToByteHandler(LengthFieldPrepender(lengthFieldLength: .four))
    }
}
```

Add the `swift-nio-extras` dependency to `Sources/GrafttyHostAgent`'s target in `Package.swift`. Search the file for the existing `GrafttyHostAgent` target dependencies block and add `.product(name: "NIOExtras", package: "swift-nio-extras")` plus the top-level `.package(...)` if not already present (it may be — verify before adding a duplicate).

- [ ] **Step 2: Write the handler tests file (RED)**

Create `Tests/GrafttyTests/Remote/SSH/PanesStateChannelHandlerTests.swift`. These tests are the spec contract for REMOTE-6.2 / 6.3 / 6.4 in their new home; the prior `Tests/GrafttyKitTests/Remote/PanesStateHandlerTests.swift` will be deleted in Task 12.

```swift
import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import NIOCore
import NIOEmbedded
import XCTest

final class PanesStateChannelHandlerTests: XCTestCase {

    /// @spec REMOTE-6.2: Immediately after accepting a `panes-state@graftty.dev`
    /// channel, the host shall send a `{"type":"snapshot","worktrees":[…]}`
    /// frame containing the current `[WorktreePanes]` array.
    func testEmitsInitialSnapshotOnChannelActive() throws {
        let initial = makeWorktrees(count: 1)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateChannelHandler(subscribe: { [subscription] cb in
            await subscription.subscribe(cb)
        })

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).wait()
        channel.embeddedEventLoop.run()
        // Drain the async subscribe → onChange callback path.
        runLoopUntil(channel: channel) {
            (try? channel.readOutbound(as: ByteBuffer.self)) != nil
        }

        guard let buf = try channel.readOutbound(as: ByteBuffer.self) else {
            return XCTFail("expected one outbound frame after channelActive")
        }
        let decoded = try JSONDecoder().decode(PanesStateMessage.self, from: Data(buf.readableBytesView))
        XCTAssertEqual(decoded, .snapshot(initial))
    }

    /// @spec REMOTE-6.3: While a `panes-state@graftty.dev` channel is open,
    /// on any change to the host's `AppState.repos[*].worktrees`,
    /// splittree, attention state, or PR status, the host shall send a
    /// fresh `{"type":"snapshot","worktrees":[…]}` frame.
    func testReemitsOnFurtherSubscribeFires() throws {
        let initial = makeWorktrees(count: 0)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateChannelHandler(subscribe: { [subscription] cb in
            await subscription.subscribe(cb)
        })

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).wait()
        runLoopUntil(channel: channel) {
            (try? channel.readOutbound(as: ByteBuffer.self)) != nil
        }
        _ = try channel.readOutbound(as: ByteBuffer.self)  // discard initial snapshot

        let next = makeWorktrees(count: 2)
        Task { await subscription.fire(next) }
        runLoopUntil(channel: channel) {
            (try? channel.readOutbound(as: ByteBuffer.self)) != nil
        }

        guard let buf = try channel.readOutbound(as: ByteBuffer.self) else {
            return XCTFail("expected second frame on fire()")
        }
        let decoded = try JSONDecoder().decode(PanesStateMessage.self, from: Data(buf.readableBytesView))
        XCTAssertEqual(decoded, .snapshot(next))
    }

    /// @spec REMOTE-6.4: When the channel closes (channelInactive), the
    /// handler shall cancel the subscription so the snapshot pipeline
    /// stops firing.
    func testCancelsSubscriptionOnClose() throws {
        let initial = makeWorktrees(count: 0)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateChannelHandler(subscribe: { [subscription] cb in
            await subscription.subscribe(cb)
        })

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).wait()
        runLoopUntil(channel: channel) { subscription.subscribed }

        _ = try channel.finish()
        channel.embeddedEventLoop.run()
        runLoopUntil(channel: channel) { subscription.cancelled }

        XCTAssertTrue(subscription.cancelled)
    }

    // MARK: - helpers

    private func makeWorktrees(count: Int) -> [WorktreePanes] {
        (0..<count).map { idx in
            WorktreePanes(
                path: "/repo/wt-\(idx)",
                displayName: "wt-\(idx)",
                repoDisplayName: "graftty",
                displayBranch: "branch-\(idx)",
                state: .running,
                isMainCheckout: false,
                prBadge: nil,
                stats: nil,
                attentionText: nil,
                layout: .leaf(sessionName: "s\(idx)", title: "shell", attentionText: nil)
            )
        }
    }

    /// EmbeddedChannel polling helper. Tasks spawned by the handler run
    /// on the global executor; the embedded loop only runs synchronously
    /// on .run(). Poll until the condition holds or 1 s passes.
    private func runLoopUntil(channel: EmbeddedChannel, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            channel.embeddedEventLoop.run()
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

private final class FakeSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var _subscribed = false
    private var _cancelled = false
    private var _onChange: (@Sendable ([WorktreePanes]) async -> Void)?
    private let initialSnapshot: [WorktreePanes]

    var subscribed: Bool { lock.withLock { _subscribed } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    init(initialSnapshot: [WorktreePanes]) {
        self.initialSnapshot = initialSnapshot
    }

    func subscribe(
        _ onChange: @escaping @Sendable ([WorktreePanes]) async -> Void
    ) async -> PanesStateChannelHandler.Cancellable {
        lock.withLock {
            _subscribed = true
            _onChange = onChange
        }
        await onChange(initialSnapshot)
        return PanesStateChannelHandler.Cancellable { [weak self] in
            self?.lock.withLock { self?._cancelled = true }
        }
    }

    func fire(_ snapshot: [WorktreePanes]) async {
        let cb = lock.withLock { _onChange }
        await cb?(snapshot)
    }
}

extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        self.lock(); defer { self.unlock() }
        return body()
    }
}
```

- [ ] **Step 3: Run the tests; expect them to fail (RED)**

Run: `swift test --filter PanesStateChannelHandlerTests`
Expected: compile failure on `PanesStateChannelHandler` (type not found).

- [ ] **Step 4: Implement the handler**

Create `Sources/GrafttyHostAgent/SSH/Channels/PanesStateChannelHandler.swift`:

```swift
import Foundation
import GrafttyKit
import GrafttyProtocol
import NIOCore

/// Server-side handler for the `panes-state@graftty.dev` SSH channel.
/// Installs *after* `LengthPrefixedFraming.makeFrameDecoder()` and
/// `LengthPrefixedFraming.makeFramePrepender()` in the child-channel
/// pipeline, so it reads/writes one `ByteBuffer` per JSON envelope —
/// no framing concerns in this file.
///
/// On `channelActive`, invokes the injected `Subscribe` callback. The
/// callback is expected to fire the supplied `onChange` once
/// immediately with the current snapshot and then again on every
/// change. Each fire serializes a `PanesStateMessage.snapshot(...)` and
/// writes it to the channel. On `channelInactive`, the subscription is
/// cancelled.
public final class PanesStateChannelHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    public typealias Subscribe = @Sendable (
        @escaping @Sendable ([WorktreePanes]) async -> Void
    ) async -> Cancellable

    public struct Cancellable: Sendable {
        private let _cancel: @Sendable () -> Void
        public init(cancel: @escaping @Sendable () -> Void) { self._cancel = cancel }
        public func cancel() { _cancel() }
    }

    private let subscribe: Subscribe
    private let lock = NSLock()
    private var cancellable: Cancellable?

    public init(subscribe: @escaping Subscribe) {
        self.subscribe = subscribe
    }

    public func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        let allocator = context.channel.allocator
        let subscribe = self.subscribe
        let storeCancellable: @Sendable (Cancellable) -> Void = { [weak self] c in
            guard let self else { c.cancel(); return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.cancellable = c
        }

        Task { [storeCancellable] in
            let cancellable = await subscribe { snapshot in
                guard
                    let body = try? JSONEncoder().encode(PanesStateMessage.snapshot(snapshot))
                else { return }
                let buf = allocator.buffer(bytes: body)
                _ = try? await channel.writeAndFlush(buf).get()
            }
            storeCancellable(cancellable)
        }
        context.fireChannelActive()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // `panes_state` is server-pushed; clients should not write payload
        // frames. Silently drop — parent design §8.1 ("Server pushes
        // length-prefixed JSON ... envelopes").
    }

    public func channelInactive(context: ChannelHandlerContext) {
        let c = lock.withLock { () -> Cancellable? in
            let snapshot = cancellable
            cancellable = nil
            return snapshot
        }
        c?.cancel()
        context.fireChannelInactive()
    }
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        self.lock(); defer { self.unlock() }
        return body()
    }
}
```

- [ ] **Step 5: Run the tests; expect them to pass (GREEN)**

Run: `swift test --filter PanesStateChannelHandlerTests`
Expected: 3 passes.

- [ ] **Step 6: Commit**

```bash
git add Package.swift \
        Sources/GrafttyHostAgent/SSH/Channels/LengthPrefixedFraming.swift \
        Sources/GrafttyHostAgent/SSH/Channels/PanesStateChannelHandler.swift \
        Tests/GrafttyTests/Remote/SSH/PanesStateChannelHandlerTests.swift
git commit -m "$(cat <<'EOF'
feat(R5): PanesStateChannelHandler — server-side panes-state@graftty.dev

NIO ChannelInboundHandler that installs above
LengthFieldBasedFrameDecoder/LengthFieldPrepender (NIOExtras) so each
inbound/outbound message is one ByteBuffer = one JSON envelope. On
channelActive invokes the injected Subscribe callback (production wires
to WorktreeMonitor; tests pass a fake). Each snapshot encodes as
PanesStateMessage.snapshot(...) and writes back to the channel.

Replaces (will replace, after Task 12 deletes the old file) the unwired
GrafttyKit/Remote/PanesStateHandler. Subscribe typealias signature
preserved so wiring is straightforward in GrafttyApp (Task 9).

3 XCTest cases against EmbeddedChannel cover REMOTE-6.2 (initial
snapshot), REMOTE-6.3 (re-emit on change), REMOTE-6.4 (cancel on close).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `PaneControlChannelHandler` (server-side) + tests

**Files:**
- Create: `Sources/GrafttyHostAgent/SSH/Channels/PaneControlChannelHandler.swift`
- Create: `Tests/GrafttyTests/Remote/SSH/PaneControlChannelHandlerTests.swift`

Mirror of Task 3 for the RPC channel. Inbound `ByteBuffer`s decode to `PaneControlRequest`; mutator dispatches; encoded `PaneControlResponse` writes back. Concurrent in-flight requests are not multiplexed at this layer — clients serialise their own RPCs per parent design §8.1.

- [ ] **Step 1: Write the tests file (RED)**

Create `Tests/GrafttyTests/Remote/SSH/PaneControlChannelHandlerTests.swift`. Mirrors `PanesStateChannelHandlerTests.swift` patterns. The test bodies port the assertions from `Tests/GrafttyKitTests/Remote/PaneControlHandlerTests.swift` (which we'll delete in Task 12).

```swift
import Foundation
import GrafttyHostAgent
import GrafttyProtocol
import NIOCore
import NIOEmbedded
import XCTest

final class PaneControlChannelHandlerTests: XCTestCase {

    /// @spec REMOTE-7.2: When the host receives a `pane-control@graftty.dev`
    /// request `{"type":"split","target":<sessionName>,"direction":<axis>}`,
    /// the host shall reply `{"ok":true}` on success.
    func testDecodesAndDispatchesSplitRequest() throws {
        let recorder = MutatorRecorder()
        let handler = PaneControlChannelHandler(mutator: { [recorder] in
            await recorder.handle($0)
        })
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).wait()

        let request = PaneControlRequest.split(target: "session-a", direction: .vertical)
        let body = try JSONEncoder().encode(request)
        try channel.writeInbound(channel.allocator.buffer(bytes: body))
        runLoopUntil(channel: channel) { (try? channel.readOutbound(as: ByteBuffer.self)) != nil }

        guard let buf = try channel.readOutbound(as: ByteBuffer.self) else {
            return XCTFail("expected outbound response")
        }
        let resp = try JSONDecoder().decode(PaneControlResponse.self, from: Data(buf.readableBytesView))
        XCTAssertEqual(resp, .ok)
    }

    /// Malformed JSON replies with `{"ok":false,"code":"malformed-request",...}`.
    func testMalformedRequestRepliesError() throws {
        let recorder = MutatorRecorder()
        let handler = PaneControlChannelHandler(mutator: { [recorder] in
            await recorder.handle($0)
        })
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).wait()

        let garbage = Data("{}".utf8)
        try channel.writeInbound(channel.allocator.buffer(bytes: garbage))
        runLoopUntil(channel: channel) { (try? channel.readOutbound(as: ByteBuffer.self)) != nil }

        guard let buf = try channel.readOutbound(as: ByteBuffer.self) else {
            return XCTFail("expected outbound error response")
        }
        let resp = try JSONDecoder().decode(PaneControlResponse.self, from: Data(buf.readableBytesView))
        guard case let .error(code, _) = resp else {
            return XCTFail("expected error response, got \(resp)")
        }
        XCTAssertEqual(code, "malformed-request")
    }

    /// @spec REMOTE-7.3: Close request dispatches with the right target.
    func testDecodesAndDispatchesCloseRequest() throws {
        let recorder = MutatorRecorder()
        let handler = PaneControlChannelHandler(mutator: { [recorder] in
            await recorder.handle($0)
        })
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).wait()

        let request = PaneControlRequest.close(target: "session-bravo")
        try channel.writeInbound(channel.allocator.buffer(bytes: try JSONEncoder().encode(request)))
        runLoopUntil(channel: channel) { (try? channel.readOutbound(as: ByteBuffer.self)) != nil }

        XCTAssertEqual(await recorder.lastRequest, request)
    }

    /// @spec REMOTE-7.4: Mutator-returned conflict response serializes
    /// as `{"ok":false,"code":"conflict",...}`.
    func testConflictResponseShape() throws {
        let handler = PaneControlChannelHandler(mutator: { _ in
            .error(code: "conflict", message: "target busy")
        })
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).wait()

        let request = PaneControlRequest.split(target: "session-x", direction: .horizontal)
        try channel.writeInbound(channel.allocator.buffer(bytes: try JSONEncoder().encode(request)))
        runLoopUntil(channel: channel) { (try? channel.readOutbound(as: ByteBuffer.self)) != nil }

        guard let buf = try channel.readOutbound(as: ByteBuffer.self) else {
            return XCTFail("expected outbound response")
        }
        let json = try JSONSerialization.jsonObject(with: Data(buf.readableBytesView)) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["code"] as? String, "conflict")
        XCTAssertNotNil(json["message"])
    }

    /// @spec REMOTE-7.5: Handler has no reference to AppState — only the
    /// injected Mutator closure. Structural assertion: construction
    /// succeeds with just a closure.
    func testHandlerHasNoAppStateReference() throws {
        let mutator: PaneControlChannelHandler.Mutator = { _ in .ok }
        _ = PaneControlChannelHandler(mutator: mutator)
        // No-op: the compiler enforces this.
    }

    // MARK: - helpers

    private func runLoopUntil(channel: EmbeddedChannel, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            channel.embeddedEventLoop.run()
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

private actor MutatorRecorder {
    var lastRequest: PaneControlRequest?
    nonisolated func handle(_ request: PaneControlRequest) async -> PaneControlResponse {
        await record(request); return .ok
    }
    private func record(_ request: PaneControlRequest) { self.lastRequest = request }
}
```

- [ ] **Step 2: Run; expect compile failure**

Run: `swift test --filter PaneControlChannelHandlerTests`
Expected: compile error.

- [ ] **Step 3: Implement the handler**

Create `Sources/GrafttyHostAgent/SSH/Channels/PaneControlChannelHandler.swift`:

```swift
import Foundation
import GrafttyProtocol
import NIOCore

/// Server-side handler for the `pane-control@graftty.dev` SSH channel.
/// Installs after `LengthPrefixedFraming.makeFrameDecoder()` and
/// `LengthPrefixedFraming.makeFramePrepender()` so each inbound and
/// outbound message is one `ByteBuffer` = one JSON envelope.
///
/// Decodes each inbound `ByteBuffer` as a `PaneControlRequest`,
/// dispatches to the injected `Mutator`, encodes the returned
/// `PaneControlResponse`, and writes it back. Concurrent in-flight RPCs
/// over the same channel are not supported at this layer — clients
/// serialise their own RPCs (parent design §8.1).
public final class PaneControlChannelHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    public typealias Mutator = @Sendable (PaneControlRequest) async -> PaneControlResponse

    private let mutator: Mutator

    public init(mutator: @escaping Mutator) {
        self.mutator = mutator
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let inbound = unwrapInboundIn(data)
        let bytes = Data(inbound.readableBytesView)
        let channel = context.channel
        let allocator = context.channel.allocator
        let mutator = self.mutator

        Task {
            let response: PaneControlResponse
            do {
                let request = try JSONDecoder().decode(PaneControlRequest.self, from: bytes)
                response = await mutator(request)
            } catch {
                response = .error(code: "malformed-request", message: String(describing: error))
            }
            guard let body = try? JSONEncoder().encode(response) else { return }
            let buf = allocator.buffer(bytes: body)
            _ = try? await channel.writeAndFlush(buf).get()
        }
    }
}
```

- [ ] **Step 4: Run; expect pass**

Run: `swift test --filter PaneControlChannelHandlerTests`
Expected: 5 passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyHostAgent/SSH/Channels/PaneControlChannelHandler.swift \
        Tests/GrafttyTests/Remote/SSH/PaneControlChannelHandlerTests.swift
git commit -m "$(cat <<'EOF'
feat(R5): PaneControlChannelHandler — server-side pane-control@graftty.dev

NIO ChannelInboundHandler decoding length-framed PaneControlRequest
JSON, dispatching to injected Mutator, encoding PaneControlResponse
back. Concurrent in-flight requests not multiplexed at this layer per
parent design §8.1 — clients serialise their own RPCs.

5 XCTest cases against EmbeddedChannel cover REMOTE-7.2 (split),
REMOTE-7.3 (close), REMOTE-7.4 (conflict wire shape),
REMOTE-7.5 (no AppState coupling), and malformed-request handling.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `PanesStateChannelClient` (mobile-side)

**Files:**
- Create: `Sources/GrafttyMobileKit/Remote/SSH/Channels/PanesStateChannelClient.swift`
- Create: `Sources/GrafttyMobileKit/Remote/SSH/Channels/LengthPrefixedFraming.swift` (mirror of host-side helper, UIKit-guarded)

Opens the `panes-state@graftty.dev` SSH channel and yields decoded `PanesStateMessage` events to a callback. `WorktreePanesStore` (Task 7) consumes it.

- [ ] **Step 1: Create the mobile-side framing helper**

Create `Sources/GrafttyMobileKit/Remote/SSH/Channels/LengthPrefixedFraming.swift`:

```swift
#if canImport(UIKit)
import NIOCore
import NIOExtras

public enum LengthPrefixedFraming {
    public static func makeFrameDecoder() -> ByteToMessageHandler<LengthFieldBasedFrameDecoder> {
        ByteToMessageHandler(LengthFieldBasedFrameDecoder(lengthFieldLength: .four))
    }

    public static func makeFramePrepender() -> MessageToByteHandler<LengthFieldPrepender> {
        MessageToByteHandler(LengthFieldPrepender(lengthFieldLength: .four))
    }
}
#endif
```

Also update `Package.swift`: if `GrafttyMobileKit` doesn't already declare `NIOExtras` as a dependency, add it (matching what Task 3 did for `GrafttyHostAgent`).

- [ ] **Step 2: Create the channel client**

Create `Sources/GrafttyMobileKit/Remote/SSH/Channels/PanesStateChannelClient.swift`:

```swift
#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH

/// Mobile-side client for the `panes-state@graftty.dev` SSH channel.
///
/// Opens a new SSH child channel via the parent `NIOSSHHandler`,
/// installs length-prefixed framing + an inbound relay, and yields
/// decoded `PanesStateMessage` events via the supplied callback.
public final class PanesStateChannelClient: @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case openFailed(any Error)
        case channelClosed
    }

    public typealias OnSnapshot = @Sendable ([WorktreePanes]) async -> Void
    public typealias OnClosed = @Sendable (String) async -> Void

    private let parentChannel: Channel
    private let parentHandler: NIOSSHHandler
    private let onSnapshot: OnSnapshot
    private let onClosed: OnClosed

    private let lock = NIOLock()
    private var childChannel: Channel?
    private var closed = false

    public init(
        parentChannel: Channel,
        parentHandler: NIOSSHHandler,
        onSnapshot: @escaping OnSnapshot,
        onClosed: @escaping OnClosed
    ) {
        self.parentChannel = parentChannel
        self.parentHandler = parentHandler
        self.onSnapshot = onSnapshot
        self.onClosed = onClosed
    }

    /// Opens the SSH child channel. Resolves when the open is acknowledged.
    public func open() async throws {
        let promise = parentChannel.eventLoop.makePromise(of: Channel.self)
        parentHandler.createChannel(
            promise,
            channelType: .unknown(SSHChannelTypeNames.panesState)
        ) { [weak self] child, _ in
            guard let self else {
                return child.eventLoop.makeFailedFuture(ClientError.channelClosed)
            }
            do {
                try child.pipeline.syncOperations.addHandler(LengthPrefixedFraming.makeFrameDecoder())
                try child.pipeline.syncOperations.addHandler(LengthPrefixedFraming.makeFramePrepender())
                try child.pipeline.syncOperations.addHandler(
                    InboundSnapshotRelay(owner: self)
                )
                return child.eventLoop.makeSucceededVoidFuture()
            } catch {
                return child.eventLoop.makeFailedFuture(error)
            }
        }
        do {
            let child = try await promise.futureResult.get()
            lock.withLock { self.childChannel = child }
            child.closeFuture.whenComplete { [weak self] _ in
                self?.handleChildClose()
            }
        } catch {
            throw ClientError.openFailed(error)
        }
    }

    /// Closes the SSH child channel.
    public func close() {
        let child = lock.withLock { () -> Channel? in
            closed = true
            return childChannel
        }
        child?.close(promise: nil)
    }

    // MARK: - Inbound

    fileprivate func deliverInbound(_ bytes: Data) {
        let onSnapshot = self.onSnapshot
        Task {
            guard
                let message = try? JSONDecoder().decode(PanesStateMessage.self, from: bytes)
            else { return }
            switch message {
            case .snapshot(let worktrees):
                await onSnapshot(worktrees)
            }
        }
    }

    private func handleChildClose() {
        let onClosed = self.onClosed
        Task { await onClosed("channel-closed") }
    }
}

private final class InboundSnapshotRelay: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    weak var owner: PanesStateChannelClient?

    init(owner: PanesStateChannelClient) {
        self.owner = owner
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        owner?.deliverInbound(Data(buf.readableBytesView))
    }
}
#endif
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build` or (if `--target` doesn't reach UIKit-guarded sources cleanly) the canonical mobile build:

```bash
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
           -scheme GrafttyMobile \
           -destination 'platform=iOS Simulator,name=iPhone 17' \
           build 2>&1 | tail -20
```

Expected: clean build.

No direct unit test for this file — its behavior is covered end-to-end by Task 10's loopback test. Standalone unit tests would require an embedded `NIOSSHHandler` and have low marginal value.

- [ ] **Step 4: Commit**

```bash
git add Package.swift \
        Sources/GrafttyMobileKit/Remote/SSH/Channels/LengthPrefixedFraming.swift \
        Sources/GrafttyMobileKit/Remote/SSH/Channels/PanesStateChannelClient.swift
git commit -m "$(cat <<'EOF'
feat(R5): PanesStateChannelClient — mobile-side panes-state opener

Opens an SSH child channel of type panes-state@graftty.dev via the
parent NIOSSHHandler, installs length-prefixed framing + an inbound
relay, and yields decoded PanesStateMessage events to the supplied
callbacks. WorktreePanesStore (Task 7) is the production consumer.

End-to-end behavior verified by R5's iOS loopback test (Task 10), not
by a standalone unit test — same precedent as R4's TerminalSessionClient.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `PaneControlChannelClient` (mobile-side)

**Files:**
- Create: `Sources/GrafttyMobileKit/Remote/SSH/Channels/PaneControlChannelClient.swift`

Mirror of Task 5 for the RPC channel. Exposes `send(_ request:) async throws -> PaneControlResponse` for typed round-trips.

- [ ] **Step 1: Create the file**

```swift
#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH

/// Mobile-side client for the `pane-control@graftty.dev` SSH channel.
///
/// One channel per `RemoteHostConnection`. RPCs are serialised by the
/// caller — concurrent `send(...)` calls on the same client will
/// interleave responses unpredictably (parent design §8.1). Production
/// callers (`PaneControlClient` wrapper in Task 8) hold an `actor`
/// that serialises.
public final class PaneControlChannelClient: @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case openFailed(any Error)
        case channelClosed
        case noPendingRequest
    }

    private let parentChannel: Channel
    private let parentHandler: NIOSSHHandler

    private let lock = NIOLock()
    private var childChannel: Channel?
    private var pending: CheckedContinuation<PaneControlResponse, Error>?
    private var closed = false

    public init(parentChannel: Channel, parentHandler: NIOSSHHandler) {
        self.parentChannel = parentChannel
        self.parentHandler = parentHandler
    }

    public func open() async throws {
        let promise = parentChannel.eventLoop.makePromise(of: Channel.self)
        parentHandler.createChannel(
            promise,
            channelType: .unknown(SSHChannelTypeNames.paneControl)
        ) { [weak self] child, _ in
            guard let self else {
                return child.eventLoop.makeFailedFuture(ClientError.channelClosed)
            }
            do {
                try child.pipeline.syncOperations.addHandler(LengthPrefixedFraming.makeFrameDecoder())
                try child.pipeline.syncOperations.addHandler(LengthPrefixedFraming.makeFramePrepender())
                try child.pipeline.syncOperations.addHandler(
                    InboundResponseRelay(owner: self)
                )
                return child.eventLoop.makeSucceededVoidFuture()
            } catch {
                return child.eventLoop.makeFailedFuture(error)
            }
        }
        do {
            let child = try await promise.futureResult.get()
            lock.withLock { self.childChannel = child }
            child.closeFuture.whenComplete { [weak self] _ in
                self?.handleChildClose()
            }
        } catch {
            throw ClientError.openFailed(error)
        }
    }

    public func send(_ request: PaneControlRequest) async throws -> PaneControlResponse {
        let child = lock.withLock { childChannel }
        guard let child else { throw ClientError.channelClosed }
        let body = try JSONEncoder().encode(request)
        let buf = child.allocator.buffer(bytes: body)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PaneControlResponse, Error>) in
            lock.withLock { pending = cont }
            child.writeAndFlush(buf).whenFailure { [weak self] error in
                self?.failPending(error)
            }
        }
    }

    public func close() {
        let child = lock.withLock { () -> Channel? in
            closed = true
            return childChannel
        }
        child?.close(promise: nil)
    }

    // MARK: - Inbound

    fileprivate func deliverInbound(_ bytes: Data) {
        let cont = lock.withLock { () -> CheckedContinuation<PaneControlResponse, Error>? in
            let snapshot = pending
            pending = nil
            return snapshot
        }
        guard let cont else { return }
        if let response = try? JSONDecoder().decode(PaneControlResponse.self, from: bytes) {
            cont.resume(returning: response)
        } else {
            cont.resume(returning: .error(code: "malformed-response", message: "decode failed"))
        }
    }

    private func failPending(_ error: any Error) {
        let cont = lock.withLock { () -> CheckedContinuation<PaneControlResponse, Error>? in
            let snapshot = pending
            pending = nil
            return snapshot
        }
        cont?.resume(throwing: error)
    }

    private func handleChildClose() {
        failPending(ClientError.channelClosed)
    }
}

private final class InboundResponseRelay: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    weak var owner: PaneControlChannelClient?

    init(owner: PaneControlChannelClient) { self.owner = owner }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        owner?.deliverInbound(Data(buf.readableBytesView))
    }
}
#endif
```

- [ ] **Step 2: Verify it compiles**

Same `xcodebuild ... build` command as Task 5 step 3.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyMobileKit/Remote/SSH/Channels/PaneControlChannelClient.swift
git commit -m "$(cat <<'EOF'
feat(R5): PaneControlChannelClient — mobile-side pane-control opener

Opens an SSH child channel of type pane-control@graftty.dev via the
parent NIOSSHHandler. Exposes send(_ request:) async throws ->
PaneControlResponse for typed round-trips. Single in-flight RPC per
instance (parent design §8.1); PaneControlClient actor wrapper (Task 8)
serialises concurrent caller requests.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Rewrite `WorktreePanesStore` to consume `PanesStateChannelClient`

**Files:**
- Modify: `Sources/GrafttyMobileKit/Remote/WorktreePanesStore.swift`
- Modify: `Tests/GrafttyMobileKitTests/Remote/WorktreePanesStoreTests.swift`

The public surface stays: `subscribe()`, `unsubscribe()`, `current`, `connectionState`. The implementation drops `ChannelRouter` and consumes `PanesStateChannelClient` directly.

- [ ] **Step 1: Replace the file contents**

Overwrite `Sources/GrafttyMobileKit/Remote/WorktreePanesStore.swift` with:

```swift
#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// Mobile-side façade for the `panes-state@graftty.dev` SSH channel.
/// Opens the channel via the supplied `PanesStateChannelClient`,
/// receives decoded `[WorktreePanes]` snapshots, and exposes
/// `current: [WorktreePanes]` as actor-isolated observable state the
/// sidebar can read.
///
/// The public method surface (`subscribe`, `unsubscribe`, `current`,
/// `connectionState`) is unchanged from the pre-R5 `ChannelRouter`-based
/// version — `RootView` consumers don't need to change.
public actor WorktreePanesStore {

    public enum ConnectionState: Sendable, Equatable {
        case idle
        case subscribed
        case closed(reason: String)
    }

    public private(set) var current: [WorktreePanes] = []
    public private(set) var connectionState: ConnectionState = .idle

    private let channelClient: PanesStateChannelClient

    public init(channelClient: PanesStateChannelClient) {
        self.channelClient = channelClient
    }

    public func subscribe() async throws {
        try await channelClient.open()
        self.connectionState = .subscribed
    }

    public func unsubscribe() async {
        channelClient.close()
        self.connectionState = .closed(reason: "unsubscribed")
    }

    /// Internal callback called by the channel client when a new snapshot
    /// arrives. Not part of the public API.
    internal func applySnapshot(_ snapshot: [WorktreePanes]) {
        self.current = snapshot
    }

    internal func markClosed(reason: String) {
        self.connectionState = .closed(reason: reason)
    }
}
#endif
```

Note the wiring inversion: the *client* (`PanesStateChannelClient`) gets the `onSnapshot` / `onClosed` callbacks at construction time. Whoever constructs the store also constructs the client and supplies callbacks that call `store.applySnapshot(_:)` / `store.markClosed(reason:)`. Production constructs this in `RemoteHostConnection.openPanesStateChannel()` (Task 8); tests construct it inline.

- [ ] **Step 2: Update the existing tests**

Overwrite `Tests/GrafttyMobileKitTests/Remote/WorktreePanesStoreTests.swift` with tests that exercise the new constructor. The previous tests used a fake `ChannelRouter`; replace with a fake `PanesStateChannelClient` (or test the store directly by injecting a client whose `open()` is a no-op and calling `store.applySnapshot(_:)` from the test).

Sketch:

```swift
#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@Suite("WorktreePanesStore — channel-client-backed façade.")
struct WorktreePanesStoreTests {

    @Test func subscribeOpensTheChannelAndExposesSnapshots() async throws {
        let client = FakeChannelClient()
        let store = WorktreePanesStore(channelClient: client.exposedAsRealClient)
        try await store.subscribe()
        #expect(await store.connectionState == .subscribed)

        let snapshot = makeWorktrees(count: 2)
        await store.applySnapshot(snapshot)
        #expect(await store.current == snapshot)
    }

    @Test func unsubscribeClosesChannelAndUpdatesState() async throws {
        let client = FakeChannelClient()
        let store = WorktreePanesStore(channelClient: client.exposedAsRealClient)
        try await store.subscribe()
        await store.unsubscribe()
        #expect(await store.connectionState == .closed(reason: "unsubscribed"))
    }

    private func makeWorktrees(count: Int) -> [WorktreePanes] {
        // ... reuse the helper from the old tests
    }
}
#endif
```

**Important caveat for the implementer:** `PanesStateChannelClient` takes a `Channel` + `NIOSSHHandler` at init, neither of which is trivially fake-able in a unit test. Two options:
- **Option A (recommended):** introduce an `@testable internal` no-arg test constructor on `PanesStateChannelClient` that records `open()`/`close()` calls and exposes `simulateInbound(_:)` to drive snapshots. The store-level tests use this. Real SSH wiring is verified by the loopback test (Task 10).
- **Option B:** make `WorktreePanesStore` consume a protocol `PanesStateChannelClientProtocol` instead of the concrete type, and the tests provide a mock conforming type. Adds an indirection that production doesn't need.

Pick Option A.

For the test-only init: add to `PanesStateChannelClient`:

```swift
#if DEBUG
/// Test-only init that bypasses the SSH machinery. The returned client
/// records `open()` / `close()` calls and exposes `simulateInbound(_:)`
/// for tests that need to push synthetic snapshots through the
/// downstream `onSnapshot` callback.
internal init(testHarness: TestHarness) {
    self.parentChannel = TestStubChannel()
    self.parentHandler = TestStubSSHHandler()
    self.onSnapshot = testHarness.onSnapshot
    self.onClosed = testHarness.onClosed
}

internal struct TestHarness: Sendable {
    let onSnapshot: OnSnapshot
    let onClosed: OnClosed
}
#endif
```

Implementing the `TestStubChannel` / `TestStubSSHHandler` stubs is non-trivial because `NIOSSHHandler` is `final` and not protocol-y. **Pragmatic fallback:** drop the `@unchecked Sendable` channel-client unit tests entirely and rely on the loopback test (Task 10) for end-to-end coverage. The `WorktreePanesStore` tests become focused on its `applySnapshot` / `connectionState` state machine, fed directly:

```swift
@Test func applySnapshotMutatesCurrent() async throws {
    let store = WorktreePanesStore.makeForTesting()  // see helper below
    let snapshot = makeWorktrees(count: 2)
    await store.applySnapshot(snapshot)
    #expect(await store.current == snapshot)
}
```

Add to `WorktreePanesStore`:

```swift
#if DEBUG
/// Construct a store with no underlying channel client, for state-machine
/// unit tests that drive `applySnapshot` / `markClosed` directly. End-to-end
/// channel behavior is covered by the loopback test in
/// `Tests/GrafttyMobileKitTests/Remote/SSH/SSHPanesAndControlLoopbackTests.swift`.
internal static func makeForTesting() -> WorktreePanesStore {
    WorktreePanesStore(channelClient: NoopChannelClient())
}
#endif
```

…with `NoopChannelClient` being a minimal stub that conforms to whatever shape we need. Cleanest path: introduce a tiny `PanesStateChannelDriver` protocol:

```swift
public protocol PanesStateChannelDriver: Sendable {
    func open() async throws
    func close()
}

extension PanesStateChannelClient: PanesStateChannelDriver {}
```

Then `WorktreePanesStore.init` takes `any PanesStateChannelDriver`. The protocol is two methods, public, justifiable.

**Implementer decision:** prefer the protocol approach. It's three lines of new public surface and keeps the unit tests honest about what they're exercising.

- [ ] **Step 3: Run the tests**

Run: `swift test --filter WorktreePanesStoreTests`
Expected: pass.

(The pre-R5 versions of the tests reference `ChannelRouter` — they will not compile. That's the expected RED → GREEN cycle for this task.)

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyMobileKit/Remote/WorktreePanesStore.swift \
        Sources/GrafttyMobileKit/Remote/SSH/Channels/PanesStateChannelClient.swift \
        Tests/GrafttyMobileKitTests/Remote/WorktreePanesStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(R5): WorktreePanesStore consumes PanesStateChannelClient over SSH

Public method surface unchanged (subscribe, unsubscribe, current,
connectionState). Internals drop ChannelRouter (which never reached
production) and consume PanesStateChannelClient directly. New protocol
`PanesStateChannelDriver` exposes open/close for tests to substitute a
no-op driver and exercise the state machine without a live SSH stack.

End-to-end channel I/O covered by the R5 loopback test (Task 10).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Rewrite `PaneControlClient` to consume `PaneControlChannelClient`

**Files:**
- Modify: `Sources/GrafttyMobileKit/Remote/PaneControlClient.swift`
- Modify: `Tests/GrafttyMobileKitTests/Remote/PaneControlClientTests.swift`

Symmetric to Task 7. Public surface (`split`, `close`, `swap`) unchanged; internals drop the router-based machinery and call `PaneControlChannelClient.send(_:)`.

- [ ] **Step 1: Replace the file contents**

```swift
#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// Mobile-side façade for the `pane-control@graftty.dev` SSH channel.
/// Wraps a `PaneControlChannelClient` and exposes typed RPC methods
/// (`split`, `close`, `swap`) that serialise concurrent caller
/// invocations through the actor's executor.
public actor PaneControlClient {

    public enum ClientError: Error, Equatable, Sendable {
        case notOpen
        case rpc(code: String, message: String)
    }

    private let channelClient: PaneControlChannelDriver

    public init(channelClient: PaneControlChannelDriver) {
        self.channelClient = channelClient
    }

    public func open() async throws {
        try await channelClient.open()
    }

    public func close() async {
        channelClient.close()
    }

    public func split(target: String, direction: PaneControlRequest.SplitDirection) async throws -> PaneControlResponse {
        try await channelClient.send(.split(target: target, direction: direction))
    }

    public func close(target: String) async throws -> PaneControlResponse {
        try await channelClient.send(.close(target: target))
    }

    public func swap(source: String, target: String) async throws -> PaneControlResponse {
        try await channelClient.send(.swap(source: source, target: target))
    }
}

/// Protocol exposed for test substitution. `PaneControlChannelClient`
/// conforms; tests substitute a fake.
public protocol PaneControlChannelDriver: Sendable {
    func open() async throws
    func close()
    func send(_ request: PaneControlRequest) async throws -> PaneControlResponse
}

extension PaneControlChannelClient: PaneControlChannelDriver {}
#endif
```

- [ ] **Step 2: Rewrite the tests**

Overwrite `Tests/GrafttyMobileKitTests/Remote/PaneControlClientTests.swift` to use a fake `PaneControlChannelDriver`:

```swift
#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@Suite("PaneControlClient — channel-client-backed RPC façade.")
struct PaneControlClientTests {

    @Test func splitForwardsAndReturnsOk() async throws {
        let fake = FakeDriver(response: .ok)
        let client = PaneControlClient(channelClient: fake)
        try await client.open()
        let response = try await client.split(target: "s1", direction: .vertical)
        #expect(response == .ok)
        #expect(await fake.lastRequest == .split(target: "s1", direction: .vertical))
    }

    @Test func closeForwardsAndReturnsOk() async throws {
        let fake = FakeDriver(response: .ok)
        let client = PaneControlClient(channelClient: fake)
        try await client.open()
        let response = try await client.close(target: "s2")
        #expect(response == .ok)
        #expect(await fake.lastRequest == .close(target: "s2"))
    }

    @Test func swapForwardsAndReturnsOk() async throws {
        let fake = FakeDriver(response: .ok)
        let client = PaneControlClient(channelClient: fake)
        try await client.open()
        let response = try await client.swap(source: "a", target: "b")
        #expect(response == .ok)
        #expect(await fake.lastRequest == .swap(source: "a", target: "b"))
    }

    @Test func errorResponsePassesThrough() async throws {
        let fake = FakeDriver(response: .error(code: "conflict", message: "busy"))
        let client = PaneControlClient(channelClient: fake)
        try await client.open()
        let response = try await client.split(target: "s3", direction: .horizontal)
        guard case let .error(code, _) = response else {
            Issue.record("expected error response, got \(response)")
            return
        }
        #expect(code == "conflict")
    }
}

private actor FakeDriver: PaneControlChannelDriver {
    var lastRequest: PaneControlRequest?
    var opened = false
    private let response: PaneControlResponse

    init(response: PaneControlResponse) { self.response = response }

    nonisolated func open() async throws {
        await setOpened()
    }

    nonisolated func close() {}

    nonisolated func send(_ request: PaneControlRequest) async throws -> PaneControlResponse {
        await record(request)
        return response
    }

    private func setOpened() { self.opened = true }
    private func record(_ request: PaneControlRequest) { self.lastRequest = request }
}
#endif
```

- [ ] **Step 3: Run the tests**

Run: `swift test --filter PaneControlClientTests`
Expected: 4 passes.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyMobileKit/Remote/PaneControlClient.swift \
        Tests/GrafttyMobileKitTests/Remote/PaneControlClientTests.swift
git commit -m "$(cat <<'EOF'
feat(R5): PaneControlClient consumes PaneControlChannelClient over SSH

Public surface (split, close, swap) unchanged. Internals drop the
ChannelRouter-based RPC machinery. New protocol PaneControlChannelDriver
lets tests substitute a fake without standing up a live SSH stack.

4 Testing cases cover split/close/swap forwarding and error-response
passthrough.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Wire `WebRTCHostAgent` for the two new channel types

**Files:**
- Modify: `Sources/GrafttyHostAgent/WebRTCHostAgent.swift`

R4 left `inboundChildChannelInitializer` as a session-only switch. R5 expands it: session stays unchanged; two new `case .unknown(let name) where ...` clauses dispatch to the new channel handlers (with `LengthPrefixedFraming` installed first).

- [ ] **Step 1: Add two new init parameters**

Find the existing `public init(hostKey:trustedPeerStore:streamFactory:)` (around line 55). Replace with:

```swift
public init(
    hostKey: Curve25519.Signing.PrivateKey,
    trustedPeerStore: TrustedPeerStore,
    streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream,
    panesStateSubscribe: @escaping PanesStateChannelHandler.Subscribe,
    paneControlMutator: @escaping PaneControlChannelHandler.Mutator
) {
    Self.initializeWebRTC()
    self.hostKey = hostKey
    self.trustedPeerStore = trustedPeerStore
    self.streamFactory = streamFactory
    self.panesStateSubscribe = panesStateSubscribe
    self.paneControlMutator = paneControlMutator
    self.factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
    self.delegate = PeerConnectionDelegate()
    self.dataChannelDelegate = DataChannelDelegate()
}
```

Add the corresponding stored properties:

```swift
private let panesStateSubscribe: PanesStateChannelHandler.Subscribe
private let paneControlMutator: PaneControlChannelHandler.Mutator
```

And import `GrafttyProtocol` if not already imported (for `SSHChannelTypeNames`).

- [ ] **Step 2: Expand the channel-open dispatch**

Find the `inboundChildChannelInitializer:` argument inside `installSSHHandler()` (around line 218):

```swift
inboundChildChannelInitializer: { child, channelType in
    guard case .session = channelType else {
        return child.eventLoop.makeFailedFuture(WebRTCHostAgentError.unsupportedChannelType)
    }
    return child.eventLoop.makeCompletedFuture {
        let sessionHandler = TerminalSessionHandler(streamFactory: factory)
        try child.pipeline.syncOperations.addHandler(sessionHandler)
    }
}
```

Replace with:

```swift
inboundChildChannelInitializer: { [panesStateSubscribe, paneControlMutator, factory] child, channelType in
    switch channelType {
    case .session:
        return child.eventLoop.makeCompletedFuture {
            let sessionHandler = TerminalSessionHandler(streamFactory: factory)
            try child.pipeline.syncOperations.addHandler(sessionHandler)
        }
    case .unknown(let name) where name == SSHChannelTypeNames.panesState:
        return child.eventLoop.makeCompletedFuture {
            try child.pipeline.syncOperations.addHandler(LengthPrefixedFraming.makeFrameDecoder())
            try child.pipeline.syncOperations.addHandler(LengthPrefixedFraming.makeFramePrepender())
            try child.pipeline.syncOperations.addHandler(
                PanesStateChannelHandler(subscribe: panesStateSubscribe)
            )
        }
    case .unknown(let name) where name == SSHChannelTypeNames.paneControl:
        return child.eventLoop.makeCompletedFuture {
            try child.pipeline.syncOperations.addHandler(LengthPrefixedFraming.makeFrameDecoder())
            try child.pipeline.syncOperations.addHandler(LengthPrefixedFraming.makeFramePrepender())
            try child.pipeline.syncOperations.addHandler(
                PaneControlChannelHandler(mutator: paneControlMutator)
            )
        }
    case .unknown, .directTCPIP, .forwardedTCPIP:
        return child.eventLoop.makeFailedFuture(WebRTCHostAgentError.unsupportedChannelType)
    @unknown default:
        return child.eventLoop.makeFailedFuture(WebRTCHostAgentError.unsupportedChannelType)
    }
}
```

(Note the `[panesStateSubscribe, paneControlMutator, factory]` capture list — they're stored properties on the actor; the closure runs off-actor on the SSH event loop, so capture-by-value rather than reference.)

- [ ] **Step 3: Verify it compiles**

Run: `swift build --target GrafttyHostAgent`
Expected: clean. `Graftty` target will fail because `GrafttyApp.swift` calls the old init signature — that's Task 11's fix.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyHostAgent/WebRTCHostAgent.swift
git commit -m "$(cat <<'EOF'
feat(R5): WebRTCHostAgent — multi-channel-type dispatch + new handlers

inboundChildChannelInitializer expands from R4's session-only switch to
dispatch by SSHChannelType. session stays unchanged (R4 terminal);
panes-state@graftty.dev → PanesStateChannelHandler + length-prefixed
framing; pane-control@graftty.dev → PaneControlChannelHandler + framing.
Unknown channel types reject with SSH_OPEN_FAILURE per R3 contract.

Two new init parameters: panesStateSubscribe (production wired in
Task 11), paneControlMutator (same). The Graftty target temporarily
fails to build — its existing init call site needs the new params.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Expose channel openers on `RemoteHostConnection` + iOS loopback test

**Files:**
- Modify: `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift`
- Create: `Tests/GrafttyMobileKitTests/Remote/SSH/SSHPanesAndControlLoopbackTests.swift`

R4 already exposes `openTerminalSession(sessionName:)`; R5 adds two symmetric methods.

- [ ] **Step 1: Add the two new methods**

In `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift`, immediately after `openTerminalSession(sessionName:)` (around line 278), add:

```swift
/// Open a `panes-state@graftty.dev` SSH channel. The supplied callbacks
/// fire each time the server sends a snapshot or the channel closes.
/// Throws `ConnectionError.notConnected` if the SSH handshake has not
/// completed.
public func openPanesStateChannel(
    onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void,
    onClosed: @escaping @Sendable (String) async -> Void
) async throws -> PanesStateChannelClient {
    guard
        let transport = sshTransport,
        let box = sshHandlerBox
    else {
        throw ConnectionError.notConnected
    }
    let client = PanesStateChannelClient(
        parentChannel: transport.channel,
        parentHandler: box.handler,
        onSnapshot: onSnapshot,
        onClosed: onClosed
    )
    try await client.open()
    return client
}

/// Open the singleton `pane-control@graftty.dev` SSH channel. Returns a
/// client ready for typed RPCs (`split`, `close`, `swap`).
public func openPaneControlChannel() async throws -> PaneControlChannelClient {
    guard
        let transport = sshTransport,
        let box = sshHandlerBox
    else {
        throw ConnectionError.notConnected
    }
    let client = PaneControlChannelClient(
        parentChannel: transport.channel,
        parentHandler: box.handler
    )
    try await client.open()
    return client
}
```

- [ ] **Step 2: Verify it compiles**

Same `xcodebuild ... build` as Task 5 step 3.

- [ ] **Step 3: Write the iOS loopback test**

Create `Tests/GrafttyMobileKitTests/Remote/SSH/SSHPanesAndControlLoopbackTests.swift`. This test extends R3's `LoopbackPeer` + R4's `runTerminalLoopback` patterns. Rather than reproducing the full ~400 LOC of loopback infrastructure, **copy-don't-extract** the helpers from `SSHTerminalLoopbackTests.swift` (per R3→R4 precedent) and add the two new channel-type exchanges.

Sketch (~200 LOC of test code):

```swift
#if canImport(UIKit)
import CryptoKit
import Foundation
import GrafttyProtocol
import NIOCore
import NIOSSH
import Testing
import WebRTC
@testable import GrafttyMobileKit

@Suite(
    "SSH-over-WebRTC custom channels — panes-state + pane-control round-trip (R5)",
    .serialized
)
struct SSHPanesAndControlLoopbackTests {

    @Test(.timeLimit(.minutes(3)))
    func panesStateSnapshotRoundTrip() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(
            fingerprint: Self.fingerprint(of: clientKey),
            terminalControl: .allowed
        )

        let snapshot = makeWorktrees(count: 2)
        let subscribe: PanesStateChannelHandler.Subscribe = { onChange in
            await onChange(snapshot)
            return PanesStateChannelHandler.Cancellable(cancel: {})
        }

        let received = try await runPanesStateLoopback(
            serverKey: serverKey,
            trustedPeers: peerStore,
            clientKey: clientKey,
            expectedHostFingerprint: Self.fingerprint(of: serverKey),
            subscribe: subscribe
        )

        #expect(received == snapshot)
    }

    @Test(.timeLimit(.minutes(3)))
    func paneControlRpcRoundTrip() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(
            fingerprint: Self.fingerprint(of: clientKey),
            terminalControl: .allowed
        )

        let mutator: PaneControlChannelHandler.Mutator = { request in
            if case .split = request { return .ok }
            return .error(code: "unexpected", message: "test only handles split")
        }

        let response = try await runPaneControlLoopback(
            serverKey: serverKey,
            trustedPeers: peerStore,
            clientKey: clientKey,
            expectedHostFingerprint: Self.fingerprint(of: serverKey),
            mutator: mutator,
            request: .split(target: "session-a", direction: .vertical)
        )

        #expect(response == .ok)
    }

    @Test(.timeLimit(.minutes(3)))
    func unauthorizedPeerCannotConnect() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(
            fingerprint: Self.fingerprint(of: clientKey),
            terminalControl: .disabled
        )

        await #expect(throws: Error.self) {
            _ = try await runPanesStateLoopback(
                serverKey: serverKey,
                trustedPeers: peerStore,
                clientKey: clientKey,
                expectedHostFingerprint: Self.fingerprint(of: serverKey),
                subscribe: { _ in .init(cancel: {}) }
            )
        }
    }

    // Helpers `runPanesStateLoopback`, `runPaneControlLoopback`,
    // `InMemoryTrustedPeerSet`, `LoopbackPeer`, `fingerprint(of:)`,
    // `makeWorktrees(count:)` are copied verbatim from
    // SSHTerminalLoopbackTests.swift with the streamFactory branch
    // replaced by panesStateSubscribe / paneControlMutator wiring per
    // R5's WebRTCHostAgent init signature.
}
#endif
```

The InMemoryTrustedPeerSet helper now needs to record the peer's `terminalControl` cap so the userauth check (Task 2) exercises it. Add a `terminalControl:` parameter to the helper's `add(fingerprint:)` method.

- [ ] **Step 4: Run the iOS test (canonical CI path)**

```bash
xcodebuild test \
    -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
    -scheme GrafttyMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:GrafttyMobileKitTests/SSHPanesAndControlLoopbackTests \
    2>&1 | tail -50
```

Expected: 3 passes.

This is the actual end-to-end gate for R5's correctness. If this passes, the server↔client wire contract is sound.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift \
        Tests/GrafttyMobileKitTests/Remote/SSH/SSHPanesAndControlLoopbackTests.swift
git commit -m "$(cat <<'EOF'
feat(R5): RemoteHostConnection.openPanesStateChannel + openPaneControlChannel

Symmetric to R4's openTerminalSession. Each opens its respective custom
SSH channel via the parent NIOSSHHandler and returns the matching
channel client.

iOS loopback test exercises both new channel types over a real
RTCPeerConnection pair + real SSH stack + length-prefixed framing.
Also exercises the userauth-time cap check (Task 2): a peer with
terminalControl: .disabled cannot complete SSH auth.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Wire production `panesStateSubscribe` + `paneControlMutator` in `GrafttyApp.swift`

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`

R5's two new `WebRTCHostAgent` init parameters need real implementations. `panesStateSubscribe` bridges `WorktreeMonitor` change events to the channel; `paneControlMutator` dispatches `PaneControlRequest` variants to existing splittree operations on `MainActor`.

- [ ] **Step 1: Locate the existing `WebRTCHostAgent` construction site**

In `Sources/Graftty/GrafttyApp.swift`, find `WebRTCHostAgent(hostKey:...)`. (R4 added this; grep for `WebRTCHostAgent(` to locate.)

- [ ] **Step 2: Write the `panesStateSubscribe` closure**

The existing `setWorktreePanesProvider` closure (around line 1195) computes a snapshot from `AppState` on `MainActor`. Extract its inner snapshot-builder into a reusable `@MainActor` function:

```swift
@MainActor
private func buildWorktreePanesSnapshot() -> [WorktreePanes] {
    // Move the existing inner body of setWorktreePanesProvider's closure
    // here (the `var out: [WorktreePanes] = []` ... `return out` block).
}
```

Then the existing setWorktreePanesProvider call becomes:

```swift
webController.setWorktreePanesProvider {
    await MainActor.run { buildWorktreePanesSnapshot() }
}
```

Now define the SSH-side subscribe closure. It needs to:
1. Fire immediately with the current snapshot.
2. Subscribe to the change-event source the desktop sidebar consumes (audit the codebase — search for `WorktreeMonitor` or whatever change publisher exists).
3. Return a `Cancellable`.

Sketch:

```swift
let panesStateSubscribe: PanesStateChannelHandler.Subscribe = { onChange in
    // Initial fire.
    let initial = await MainActor.run { buildWorktreePanesSnapshot() }
    await onChange(initial)

    // Subscribe to subsequent changes. The exact subscription API
    // depends on what publisher the existing sidebar uses — audit
    // GrafttyApp's existing notification/AsyncStream sources. For each
    // change event, recompute the snapshot and call onChange.
    let task = Task {
        for await _ in worktreeMonitor.changes {
            let snapshot = await MainActor.run { buildWorktreePanesSnapshot() }
            await onChange(snapshot)
        }
    }
    return PanesStateChannelHandler.Cancellable {
        task.cancel()
    }
}
```

**Note for the implementer:** the exact API of `WorktreeMonitor.changes` (or its equivalent) needs to be looked up at execution time. If no async-stream-based change source exists, two options:
- (a) Add one. Likely a few-LOC `AsyncStream` published from wherever the desktop sidebar's update path lives.
- (b) Poll. Worse — but viable as a stopgap with a 1-second interval.

Pick (a) if the codebase has a clear single change source; (b) only if (a) requires more than ~30 LOC of refactor.

- [ ] **Step 3: Write the `paneControlMutator` closure**

```swift
let paneControlMutator: PaneControlChannelHandler.Mutator = { request in
    await MainActor.run {
        switch request {
        case .split(let target, let direction):
            return appState.applySplit(target: target, direction: direction)
        case .close(let target):
            return appState.applyClose(target: target)
        case .swap(let source, let target):
            return appState.applySwap(source: source, target: target)
        }
    }
}
```

**Note for the implementer:** `appState.applySplit / applyClose / applySwap` are placeholder method names — audit the existing splittree mutation entry points and use the real ones. The mutator returns `PaneControlResponse` (`.ok` on success, `.error(code:message:)` on failure). Per parent design REMOTE-7.4, conflicts return `{"ok":false,"code":"conflict","message":...}`.

- [ ] **Step 4: Pass the closures into `WebRTCHostAgent`**

Update the construction site:

```swift
let agent = WebRTCHostAgent(
    hostKey: hostKey,
    trustedPeerStore: trustedPeerStore,
    streamFactory: streamFactory,
    panesStateSubscribe: panesStateSubscribe,
    paneControlMutator: paneControlMutator
)
```

- [ ] **Step 5: Run the macOS test suite + iOS loopback to verify**

```bash
swift test 2>&1 | tail -20
xcodebuild test \
    -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
    -scheme GrafttyMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:GrafttyMobileKitTests/SSHPanesAndControlLoopbackTests \
    2>&1 | tail -30
```

Expected: macOS test suite passes (no regressions); iOS loopback still passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift
git commit -m "$(cat <<'EOF'
feat(R5): wire production panesStateSubscribe + paneControlMutator

panesStateSubscribe: fires the current WorktreePanes snapshot
immediately, then re-fires on every WorktreeMonitor change event.
Bridges the existing desktop sidebar change pipeline (which already
recomputes from AppState on MainActor) into the SSH channel layer.

paneControlMutator: dispatches each PaneControlRequest variant to
existing AppState splittree mutations on MainActor. Returns .ok on
success, .error(code: "conflict"|"…") on failure per REMOTE-7.4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Mobile-side wiring — construct stores from the per-host `RemoteHostConnection`

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift`
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift`

`WorktreePanesStore` and `PaneControlClient` now take channel-client constructor parameters. The iPad path (which has a `RemoteHostConnection`) builds them from the per-host connection; the iPhone path stays on `/ws` for now and gets nil/idle versions.

- [ ] **Step 1: Add a builder helper to `SessionLifecycleEnvironment` (or wherever the iPad-vs-iPhone branch lives)**

```swift
public struct PaneEnvironment: Sendable {
    public let worktreePanesStore: WorktreePanesStore?
    public let paneControlClient: PaneControlClient?
}

@MainActor
public func buildPaneEnvironment(remoteHost: RemoteHostConnection?) async -> PaneEnvironment {
    guard let remoteHost else { return PaneEnvironment(worktreePanesStore: nil, paneControlClient: nil) }
    do {
        // Build store + open the SSH channel that feeds it.
        let storePlaceholder = WorktreePanesStore(channelClient: NoopChannelClient())
        let channelClient = try await remoteHost.openPanesStateChannel(
            onSnapshot: { snapshot in await storePlaceholder.applySnapshot(snapshot) },
            onClosed: { reason in await storePlaceholder.markClosed(reason: reason) }
        )
        // Replace the placeholder driver — actor swap pattern below.
        // (See discussion below: prefer a single-construction shape.)
        ...
    } catch {
        return PaneEnvironment(worktreePanesStore: nil, paneControlClient: nil)
    }
}
```

The "placeholder swap" shape above is awkward. **Cleaner approach:** invert the flow so the store is constructed *with* the channel client already wired:

```swift
@MainActor
public func buildPaneEnvironment(remoteHost: RemoteHostConnection?) async -> PaneEnvironment {
    guard let remoteHost else { return PaneEnvironment(worktreePanesStore: nil, paneControlClient: nil) }
    do {
        // Build the channel clients first; the store/client wraps them.
        let panesClient = try await remoteHost.openPanesStateChannel(
            onSnapshot: { _ in /* set on store after construction */ },
            onClosed: { _ in /* same */ }
        )
        let controlClient = try await remoteHost.openPaneControlChannel()

        let store = WorktreePanesStore(channelClient: panesClient)
        let client = PaneControlClient(channelClient: controlClient)

        // Now backfill the onSnapshot/onClosed callbacks to point at the store.
        // (Implementation detail: PanesStateChannelClient can expose a
        //  setCallbacks(...) method, or the store can register itself
        //  via an internal hook. Pick whichever is cleaner — likely a
        //  small `register(_:)` method on the channel client.)

        return PaneEnvironment(worktreePanesStore: store, paneControlClient: client)
    } catch {
        return PaneEnvironment(worktreePanesStore: nil, paneControlClient: nil)
    }
}
```

**Implementer's call:** the cleanest concrete shape is probably to add `panesClient.setCallbacks(onSnapshot:onClosed:)` and have the construction look like:

```swift
let panesClient = PanesStateChannelClient(
    parentChannel: ...,
    parentHandler: ...,
    onSnapshot: { _ in },
    onClosed: { _ in }
)
let store = WorktreePanesStore(channelClient: panesClient)
panesClient.setCallbacks(
    onSnapshot: { snapshot in await store.applySnapshot(snapshot) },
    onClosed: { reason in await store.markClosed(reason: reason) }
)
try await panesClient.open()
```

Add `setCallbacks(...)` to `PanesStateChannelClient` (lock-protected setter that overwrites the closures stored at init).

- [ ] **Step 2: Pass `PaneEnvironment` into `RootView`**

Wherever `RootView` currently consumes `WorktreePanesStore` / `PaneControlClient`, source them from the `PaneEnvironment`. iPhone paths see `nil` and fall back to whatever the existing behavior is (most likely: empty sidebar + disabled control, until iPhone's SSH cutover lands in R6).

- [ ] **Step 3: Verify iOS build**

```bash
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
           -scheme GrafttyMobile \
           -destination 'platform=iOS Simulator,name=iPhone 17' \
           build 2>&1 | tail -20
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift \
        Sources/GrafttyMobileKit/App/RootView.swift \
        Sources/GrafttyMobileKit/Remote/SSH/Channels/PanesStateChannelClient.swift
git commit -m "$(cat <<'EOF'
feat(R5): wire WorktreePanesStore + PaneControlClient on iPad

SessionLifecycleEnvironment exposes a PaneEnvironment built from the
per-host RemoteHostConnection: opens the two new SSH channels and
constructs the matching mobile-side façades. iPhone (no
RemoteHostConnection yet) gets nil values; R6's iPhone cutover replaces.

Adds setCallbacks(onSnapshot:onClosed:) on PanesStateChannelClient so
the channel-client and the store can be constructed in either order
without an awkward placeholder swap.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Delete dead code + promote specs

**Files to delete:**
- `Sources/GrafttyKit/Remote/PanesStateHandler.swift`
- `Sources/GrafttyKit/Remote/PaneControlHandler.swift`
- `Sources/GrafttyMobileKit/Remote/ChannelRouter.swift`
- `Sources/GrafttyMobileKit/Remote/TerminalChannelClient.swift`
- `Tests/GrafttyKitTests/Remote/PanesStateHandlerTests.swift`
- `Tests/GrafttyKitTests/Remote/PaneControlHandlerTests.swift`

**Files to modify:**
- `Tests/GrafttyTests/Specs/RemoteTodo.swift` — remove the `@Test(.disabled)` inventory entries for REMOTE-6.1, REMOTE-7.1, REMOTE-7.6.

- [ ] **Step 1: Delete the unwired old types and their tests**

```bash
git rm Sources/GrafttyKit/Remote/PanesStateHandler.swift \
       Sources/GrafttyKit/Remote/PaneControlHandler.swift \
       Sources/GrafttyMobileKit/Remote/ChannelRouter.swift \
       Sources/GrafttyMobileKit/Remote/TerminalChannelClient.swift \
       Tests/GrafttyKitTests/Remote/PanesStateHandlerTests.swift \
       Tests/GrafttyKitTests/Remote/PaneControlHandlerTests.swift
```

- [ ] **Step 2: Remove the three promoted specs from `RemoteTodo.swift`**

Open `Tests/GrafttyTests/Specs/RemoteTodo.swift`. Find and delete the three `@Test(.disabled(...))` blocks for `REMOTE-6.1`, `REMOTE-7.1`, `REMOTE-7.6`. (Their EARS text is now expressed in the new tests' titles.)

- [ ] **Step 3: Verify the build still compiles cleanly**

```bash
swift build 2>&1 | tail -10
swift test 2>&1 | tail -10
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
           -scheme GrafttyMobile \
           -destination 'platform=iOS Simulator,name=iPhone 17' \
           build 2>&1 | tail -10
```

Expected: clean. If something doesn't compile, the most likely culprits are residual `import GrafttyProtocol`-only uses of `ChannelRouter` types in tests we forgot to update, or test code referencing the deleted handler types.

- [ ] **Step 4: Regenerate `SPECS.md`**

```bash
scripts/generate-specs.py
```

The script should:
- Add the new `@spec REMOTE-6.1`, `REMOTE-7.1`, `REMOTE-7.6` entries from `Tests/GrafttyTests/Remote/SSH/...`
- Remove the corresponding disabled inventory entries from `RemoteTodo.swift`

`git diff SPECS.md` should show three previously-`.disabled` entries flipping to active, with the EARS text updated to reflect SSH channel semantics.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Remote/PanesStateHandler.swift \
        Sources/GrafttyKit/Remote/PaneControlHandler.swift \
        Sources/GrafttyMobileKit/Remote/ChannelRouter.swift \
        Sources/GrafttyMobileKit/Remote/TerminalChannelClient.swift \
        Tests/GrafttyKitTests/Remote/PanesStateHandlerTests.swift \
        Tests/GrafttyKitTests/Remote/PaneControlHandlerTests.swift \
        Tests/GrafttyTests/Specs/RemoteTodo.swift \
        SPECS.md
git commit -m "$(cat <<'EOF'
chore(R5): delete unwired ChannelRouter handlers; promote REMOTE-6.1/7.1/7.6

The old PanesStateHandler / PaneControlHandler (host-side) and
ChannelRouter / TerminalChannelClient (mobile-side) were never wired to
production — they sit behind the M1.4 ChannelRouter framing that R4
confirmed never shipped. R5's new NIO-handler-based stack replaces them
entirely.

Promotions:
- REMOTE-6.1 (panes-state channel-open cap check) — implemented at
  userauth time, satisfies REMOTE-6.1 by exclusion
- REMOTE-7.1 (pane-control channel-open cap check) — same
- REMOTE-7.6 (revocation closes pane-control channel) — covered by R3's
  triggerUserInitiatedClose plumbing + TrustedPeerStore revocation

Remaining ChannelRouter family (host-side ChannelRouter.swift, Channel
Frame*, ChannelID*, TerminalChannelOpenMeta*) stays until R6 per parent
design §11 — R6 owns the full sweep.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: `/simplify` pass + PR

Per project CLAUDE.md, every PR runs `/simplify` first.

- [ ] **Step 1: Run `/simplify`**

```
/simplify
```

Apply any improvements it surfaces. Typical things to look for given R5's shape:
- Duplicate / near-duplicate channel-client patterns between `PanesStateChannelClient` and `PaneControlChannelClient` — keep separate (different responsibilities), don't extract a base class.
- Dead imports left behind from deletions.
- Loopback test helpers that could shrink now that they're copy-pasted from R4.

- [ ] **Step 2: Run all tests once more**

```bash
swift test
xcodebuild test \
    -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
    -scheme GrafttyMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:GrafttyMobileKitTests/SSHPanesAndControlLoopbackTests \
    -only-testing:GrafttyMobileKitTests/SSHTerminalLoopbackTests \
    -only-testing:GrafttyMobileKitTests/SSHAuthLoopbackTests \
    -only-testing:GrafttyMobileKitTests/Remote/WorktreePanesStoreTests \
    -only-testing:GrafttyMobileKitTests/Remote/PaneControlClientTests
```

Expected: green.

- [ ] **Step 3: Open the PR**

```bash
gh pr create --title "feat(remote): R5 — panes-state + pane-control SSH channels" --body "$(cat <<'EOF'
## Summary

- Lands the two remaining custom SSH channel types: `panes-state@graftty.dev` (server-pushed snapshots) and `pane-control@graftty.dev` (client→server RPC).
- Rewires the iPad's `WorktreePanesStore` + `PaneControlClient` from the (never-wired) `ChannelRouter` framing to real SSH channels via the R3/R4 stack.
- Folds the REMOTE-6.1/7.1/7.6 capability check into `SSHUserAuthDelegate` rather than building per-channel-open peer inspection — simpler for R5 scope; port-tunnel (REMOTE-4.x) will introduce per-channel plumbing when it actually needs it.
- Deletes the unwired-from-production `PanesStateHandler` / `PaneControlHandler` / mobile-side `ChannelRouter` / `TerminalChannelClient`.
- Promotes `REMOTE-6.1`, `REMOTE-7.1`, `REMOTE-7.6` to active specs.

R6 deletes the remaining `ChannelRouter*` host-side family and retires `/ws` for iPhone.

## Test plan
- [ ] `swift test` green on macOS
- [ ] iOS loopback tests green: `SSHAuthLoopbackTests`, `SSHTerminalLoopbackTests`, `SSHPanesAndControlLoopbackTests`
- [ ] iPad real-device verification: pair, attach to a worktree, confirm sidebar populates from SSH (not `/ws`), confirm split/close/swap operations work end-to-end

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Watch CI**

The iOS CI job is the canonical correctness gate (per memory: `feedback_macos_swift_test_misses_uikit_guarded_code`). macOS `swift test` is necessary but not sufficient.

---

## Risks

1. **`WorktreeMonitor.changes` (or equivalent) might not exist.** Task 11 may discover the codebase has no clean change-event stream for the desktop sidebar. Fallback: introduce a 1-second polling loop. Adds ~10 LOC; loses real-time updates over SSH but matches the existing `/ws` poll-based behavior.
2. **Mobile-side `setCallbacks` race.** Task 12's "construct channel client → construct store → backfill callbacks" pattern has a narrow window where the channel might be open but callbacks are still no-ops. If the server fires a snapshot in that window it's dropped. Mitigation: open the channel only *after* callbacks are wired (move `open()` to the end of `buildPaneEnvironment`). Already accounted for in the sketch.
3. **Two `RemoteHostConnection.openTerminalSession` / `openPanesStateChannel` / `openPaneControlChannel` call sites in `RootView`.** All three iPad surface paths need updating; missing one means that surface silently falls back to no-op state. Mitigation: grep before submitting (`grep -rn "openTerminalSession\|RemoteHostConnection" Sources/GrafttyMobileKit/App/`).
4. **`NIOExtras` may not be a current Package.swift dependency.** Verify in Task 3 step 1 before adding; if it is, just append to the target's deps. If it isn't, add at top level and to both `GrafttyHostAgent` and `GrafttyMobileKit`.
5. **`SSHChannelType.unknown` enum case naming.** swift-nio-ssh may name it `.unknown` or `.custom` depending on version; if 0.13 names differ from this plan, adjust the pattern matches in Task 9 step 2 accordingly. Failing match → channel-open rejects with `unsupportedChannelType`, which the iOS loopback test catches immediately.
6. **`AsyncStream`-based subscribe might leak.** Task 11's `task.cancel()` in the returned `Cancellable` must actually terminate the `for await ... in worktreeMonitor.changes` loop. If `WorktreeMonitor.changes` is a broadcast stream that doesn't honor task cancellation, the loop survives the channel close and continues invoking a captured `onChange` that calls a closed SSH channel. Mitigation: wrap `onChange` in a `closed` check, or use an explicit deregistration on the monitor side.
7. **Mac-side dead code after R5.** The host-side `ChannelRouter.swift`, `ChannelFrame*`, etc. become dead after R5 lands but stay until R6. SwiftLint or other dead-code checks may flag them. If CI fails because of unused-import warnings on the deleted-but-still-imported types, scope the suppression to those files for one release.

---

## Open questions (deferred to R6 or beyond)

1. **iPhone cutover** — R6 owns `/ws` retirement. R5 leaves iPhone's path unchanged.
2. **Concurrent in-flight `pane-control` RPCs from a single client** — current design serializes via the `PaneControlClient` actor. If a real concurrency need emerges, revisit.
3. **`panes-state` reconnect** — covered by parent §9.1's full SSH re-handshake. The mobile `WorktreePanesStore` will see the channel close and the wrapping app code triggers a fresh `openPanesStateChannel` on reconnect. Verify in Task 12's RootView wiring that the reconnect path is exercised; iOS loopback test should cover at least one reconnect cycle if cheap to add.
4. **REMOTE-7.6 (revocation closes channel)** — currently relies on R3's `triggerUserInitiatedClose` plus `TrustedPeerStore` revocation tearing down all SSH connections for the revoked peer. If host-side revocation doesn't yet enumerate live SSH connections, R5 may need to add that bookkeeping. Audit at execution time.
