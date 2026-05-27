# SSH-over-WebRTC R4 — Terminal Session Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire SSH-over-WebRTC into the iPad's terminal path. First production WebRTC traffic in graftty — R2 and R3 added the SSH stack but only exercised it in loopback tests; R4 makes an iPad attached to a paired Mac talk to that Mac's PTYs over `WebRTC DataChannel → SSH session channel → zmx attach`.

**Architecture:** Add server-side `TerminalSessionHandler` (reads SSH env `GRAFTTY_SESSION`, accepts `pty-req` + `shell`, calls injected `streamFactory(name)` closure, bridges bytes both ways). Add mobile-side `TerminalSessionClient` that conforms to `WebSocketClient` so `SessionClient` consumes it unchanged. Wire SSH installation into `WebRTCHostAgent` (server) and `RemoteHostConnection` (mobile) — both gain a "DataChannel open → install R3 SSH layer → register channel-handler factory" step. Mac app injects a closure that spawns `zmx attach <name>` as `Process` (copy of `WebSession.start()`'s spawn logic — duplication is intentional for R4; R6 consolidates). iPad's `SessionClient.live` gains an optional `remoteHost: RemoteHostConnection?` parameter; when present, the `webSocketFactory` returns `try await remoteHost.openTerminalSession(name:)`; when nil, the existing `URLSessionWebSocketClient` path runs unchanged (iPhone stays on `/ws`).

**Tech Stack:** Swift 5.10+, swift-nio-ssh 0.13, swift-nio, WebRTC (stasel/WebRTC SDK), Swift Testing, XCTest.

**Parent design:** [`2026-05-21-ssh-over-webrtc-design.md`](../specs/2026-05-21-ssh-over-webrtc-design.md)
**R4 design (this PR):** [`2026-05-27-ssh-over-webrtc-phase-4-design.md`](../specs/2026-05-27-ssh-over-webrtc-phase-4-design.md)

---

## File Structure

**Create:**
- `Sources/GrafttyHostAgent/SSH/Channels/TerminalSessionHandler.swift` — server-side SSH channel handler
- `Sources/GrafttyMobileKit/Remote/SSH/Channels/TerminalSessionClient.swift` — mobile-side `WebSocketClient` conformer wrapping an SSH session channel
- `Tests/GrafttyTests/Remote/SSH/TerminalSessionHandlerTests.swift` — Mac-runnable unit tests for the handler
- `Tests/GrafttyMobileKitTests/Remote/SSH/SSHTerminalLoopbackTests.swift` — iOS-only end-to-end loopback test

**Modify:**
- `docs/superpowers/specs/2026-05-21-ssh-over-webrtc-design.md` — one-line clarification in §11 R4 row
- `docs/superpowers/specs/2026-05-27-ssh-over-webrtc-phase-4-design.md` — §7 wording (loopback uses fake byte stream, not real zmx)
- `Sources/GrafttyHostAgent/WebRTCHostAgent.swift` — install SSH layer after DataChannel opens; new `streamFactory` init parameter
- `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift` — install SSH client after DataChannel opens; expose `openTerminalSession(sessionName:) -> TerminalSessionClient`
- `Sources/Graftty/GrafttyApp.swift` — inject `streamFactory` closure that spawns `zmx attach <sessionName>` as a `Process`
- `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift` — `SessionClient.live(...)` gains `remoteHost: RemoteHostConnection?` parameter
- `Sources/GrafttyMobileKit/App/RootView.swift` — pass `remoteHost` at two `SessionClient.live` call sites

---

## Important Context for the Implementer

### Existing types (already on `main`)

- **`SSHServerSetup.makeHandler(hostKey:, trustedPeerStore:, allocator:, inboundChildChannelInitializer:)`** — `Sources/GrafttyHostAgent/SSH/SSHServerSetup.swift`. Returns a `NIOSSHHandler` configured with R3's userauth delegate and the AES-GCM cipher allowlist. The `inboundChildChannelInitializer` closure is the hook for R4 — when an SSH child channel opens, this closure installs handlers into its pipeline.

- **`SSHClientSetup.makeHandler(clientKey:, expectedHostFingerprint:, allocator:)`** — `Sources/GrafttyMobileKit/Remote/SSH/SSHClientSetup.swift`. Returns a `NIOSSHHandler` with `PinnedHostKeyAuthDelegate` (verifies host key against pinned fingerprint) and a single-attempt publickey userauth delegate.

- **`SSHNIOTransport(dataChannel:)`** — `Sources/GrafttyMobileKit/Remote/SSH/SSHNIOTransport.swift` and `Sources/GrafttyHostAgent/SSH/SSHNIOTransport.swift`. Adapter between `RTCDataChannel` (message stream) and NIO `Channel` (byte stream). Has `.channel: Channel`, `.eventLoop: EventLoop`, `.start() async throws`, `.close() async`. Install the SSH handler into `transport.channel.pipeline.syncOperations.addHandler(sshHandler)` before calling `.start()`.

- **`HostIdentityStore`** — `Sources/GrafttyKit/Remote/HostIdentityStore.swift`. Server's Ed25519 keypair persistence; has `loadOrCreate() throws -> Curve25519.Signing.PrivateKey`.

- **`ClientIdentityStore`** — `Sources/GrafttyMobileKit/Remote/ClientIdentityStore.swift`. Client's Ed25519 keypair persistence. `#if canImport(UIKit)`-guarded.

- **`TrustedPeerStore`** — `Sources/GrafttyKit/Remote/TrustedPeerStore.swift`. Used by `SSHUserAuthDelegate` on the server.

- **`PinnedHostStore`** — `Sources/GrafttyMobileKit/Remote/PinnedHostStore.swift`. Holds host fingerprints the client trusts. The fingerprint passed to `SSHClientSetup.makeHandler` comes from a `PinnedHost.fingerprint` lookup.

- **`WebSocketClient` protocol** — `Sources/GrafttyMobileKit/Session/WebSocketClient.swift`. Three methods: `send(_ frame: WebSocketFrame) async throws`, `receive() async throws -> WebSocketFrame`, `close()`. `TerminalSessionClient` conforms to this.

- **`WebSocketFrame`** — same file. `case text(String) | case binary(Data)`. For SSH terminal traffic, all frames are `.binary(Data)`; text frames carry control messages on `/ws` but R4 doesn't replicate that mechanism (resize is plumbed via SSH `window-change`, not a control frame).

- **`WebSession`** — `Sources/GrafttyKit/Web/WebServer.swift` line ~945. The `/ws` path's `Process(zmx attach)` spawner. R4 copies its `Process` construction into the new `streamFactory` closure in `GrafttyApp.swift` — don't extract; R6 consolidates.

### Where `GrafttyHostAgent`'s tests live

There is no `GrafttyHostAgentTests` target. R3 ran into the same constraint (its plan referenced creating one, but in the end the loopback test target `GrafttyMobileKitTests` mirrored the server delegate inline rather than introduce a new target). R4 places Mac-runnable handler tests in `Tests/GrafttyTests/Remote/SSH/` — `GrafttyTests` depends on `Graftty`, which depends on `GrafttyHostAgent`, so the types are reachable.

### NIO basics for the implementer

- An SSH child channel (the per-session "session channel" in SSH terms) is a `NIO.Channel`. You install handlers into its pipeline via `channel.pipeline.syncOperations.addHandler(...)`.
- swift-nio-ssh sends channel requests (`env`, `pty-req`, `shell`, `window-change`, `exit-status`, `signal`) as `SSHChannelRequestEvent` user-inbound events. Your handler's `userInboundEventTriggered(context:event:)` receives them.
- Channel data is `SSHChannelData` — has a `type` (`.channel` for stdout-like; `.stdErr` for stderr) and a `data: IOData` (typically `.byteBuffer`).
- For the session channel, opening order from the client is: `openChannel(type: .session)` → `env GRAFTTY_SESSION=...` (channel-request) → `pty-req` (channel-request) → `shell` (channel-request) → then bidirectional `SSHChannelData`.

### Loopback test infrastructure to reuse

R3's `SSHAuthLoopbackTests.swift` already extracted the patterns R4 reuses:
- `LoopbackPeer` — wraps an `RTCPeerConnection` + `RTCDataChannel` for in-process pairing
- `runAuthLoopback(...)` — the function that pairs the two peers, layers SSH on each side, and round-trips a request
- `LoopbackExecResponder`, `ClientSessionOpener`, `LoopbackExecCollector` — child-channel handlers for the exec test

R4 copies these (verbatim, per the precedent established by R3 copying from R2) and adds new child-channel handlers for the env+pty+shell flow.

---

## Task 1: Spec doc corrections

**Files:** `docs/superpowers/specs/2026-05-21-ssh-over-webrtc-design.md`, `docs/superpowers/specs/2026-05-27-ssh-over-webrtc-phase-4-design.md`

Two small text fixes. No code changes.

- [ ] **Step 1: Clarify parent design §11 R4 row**

Find the `| **R4** |` row in §11 of `docs/superpowers/specs/2026-05-21-ssh-over-webrtc-design.md`. Its "Scope" cell currently reads:

```
**R4** | `TerminalSessionHandler` (server) + `TerminalSessionClient` (mobile). `RemoteHostConnection` swapped from `ChannelRouter` to SSH for terminal. Terminal I/O round-trip test. iPhone still on `/ws`.
```

Replace with:

```
**R4** | `TerminalSessionHandler` (server) + `TerminalSessionClient` (mobile). `RemoteHostConnection` wired to SSH for terminal — this is the first production protocol over the DataChannel (`ChannelRouter` was never wired into production; only loopback tests exercised it). Terminal I/O round-trip test. iPhone still on `/ws`.
```

- [ ] **Step 2: Fix R4 spec §7 loopback wording**

In `docs/superpowers/specs/2026-05-27-ssh-over-webrtc-phase-4-design.md`, find the line in §7 that says:

```
- **`SSHTerminalLoopbackTests.swift`** (iOS-only, real-PTY). Extends R3's `runAuthLoopback` infrastructure. Real `zmx daemon` in tmp dir, real `zmx attach` via the streamFactory closure, real `RTCPeerConnection` pair. Smoke: `printf 'hi\n' | cat` → expect `hi\n`. `.timeLimit(.minutes(1))` per R3 precedent.
```

Replace with:

```
- **`SSHTerminalLoopbackTests.swift`** (iOS-only). Extends R3's `runAuthLoopback` infrastructure. Real `RTCPeerConnection` pair + real SSH stack; the `streamFactory` returns a fake echoing `TerminalByteStream` rather than spawning `zmx attach` (iOS Simulator doesn't have host binaries). Exercises the SSH wire end-to-end: env→pty→shell, bytes round-trip both directions, `window-change` forwarding, channel-close kills the stream. `.timeLimit(.minutes(3))` per R3 precedent (iOS CI variance). Real `zmx attach` integration is verified at the manual TestFlight gate, not in CI.
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-05-21-ssh-over-webrtc-design.md docs/superpowers/specs/2026-05-27-ssh-over-webrtc-phase-4-design.md
git commit -m "$(cat <<'EOF'
docs(R4): clarify parent design R4 row and R4 spec loopback wording

Parent design §11 R4 row implied ChannelRouter already carried production
iPad terminal traffic. It does not — PR #176 landed framing types but
neither RemoteHostConnection nor WebRTCHostAgent ever wired them into the
live DataChannel. R4 is the first PR where the iPad client opens a real
production protocol session over WebRTC.

R4 spec §7 promised a "real zmx daemon" loopback test. iOS Simulator
doesn't have host binaries, so the loopback uses a fake echoing
TerminalByteStream. Real zmx integration is verified at the manual
TestFlight gate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `TerminalSessionHandler` (server-side) + Mac unit tests

**Files:**
- Create: `Sources/GrafttyHostAgent/SSH/Channels/TerminalSessionHandler.swift`
- Create: `Tests/GrafttyTests/Remote/SSH/TerminalSessionHandlerTests.swift`

The handler installs on an SSH child channel (the session channel) and:
1. Receives `env` channel requests, stores `GRAFTTY_SESSION` if present
2. Receives `pty-req` channel request, stores window dimensions for the eventual `resize(cols:rows:)` call
3. Receives `shell` channel request — at this point we have all the context needed; call `streamFactory(sessionName)`, attach the returned `TerminalByteStream`, and start forwarding bytes both ways
4. Receives `window-change` channel requests, forwards to `stream.resize(cols:rows:)`
5. Channel close → call `stream.close()` (which kills the underlying `zmx attach` Process; shell survives in zmx daemon)
6. If `streamFactory` throws, send `exit-status: 1` and close the channel

- [ ] **Step 1: Write the unit test file**

Create `Tests/GrafttyTests/Remote/SSH/TerminalSessionHandlerTests.swift`. Note: the test target uses XCTest (matching the rest of `GrafttyTests`'s existing style — the `@spec` annotations go in `///` doc comments on test methods per CLAUDE.md). The handler is exercised in an NIO `EmbeddedChannel` against a fake stream.

```swift
import GrafttyHostAgent
import GrafttyKit
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

final class TerminalSessionHandlerTests: XCTestCase {

    // MARK: - env + pty + shell -> attach

    /// The handler stores the GRAFTTY_SESSION env, accepts pty-req,
    /// and on shell invokes streamFactory(name) with the env value.
    func testShellCallsStreamFactoryWithEnvSessionName() throws {
        let factory = RecordingStreamFactory(returning: .success(EchoStream()))
        let channel = EmbeddedChannel()
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        try channel.pipeline.syncOperations.addHandler(handler)

        try sendEnvRequest(channel: channel, name: "GRAFTTY_SESSION", value: "alpha")
        try sendPtyRequest(channel: channel, term: "xterm-256color", cols: 80, rows: 24)
        try sendShellRequest(channel: channel)

        // Drain any pending writes so the embedded channel completes futures.
        channel.embeddedEventLoop.run()

        XCTAssertEqual(factory.received, ["alpha"])
    }

    /// If no GRAFTTY_SESSION env arrives before shell, the handler
    /// rejects shell — it has no way to pick a pane.
    func testShellWithoutEnvSessionNameRejected() throws {
        let factory = RecordingStreamFactory(returning: .success(EchoStream()))
        let channel = EmbeddedChannel()
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        try channel.pipeline.syncOperations.addHandler(handler)

        try sendPtyRequest(channel: channel, term: "xterm", cols: 80, rows: 24)

        // shell with no env -> the channel-request promise should fail.
        let shellPromise = channel.eventLoop.makePromise(of: Void.self)
        let event = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        channel.pipeline.fireUserInboundEventTriggered(event)
        channel.embeddedEventLoop.run()

        XCTAssertTrue(factory.received.isEmpty)
    }

    // MARK: - bytes round-trip

    /// Bytes written to the channel forward to stream.send(); bytes
    /// emitted by the stream's inboundBytes write back out the channel.
    func testBytesRoundTripThroughStream() throws {
        let stream = EchoStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let channel = EmbeddedChannel()
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        try channel.pipeline.syncOperations.addHandler(handler)

        try sendEnvRequest(channel: channel, name: "GRAFTTY_SESSION", value: "alpha")
        try sendPtyRequest(channel: channel, term: "xterm", cols: 80, rows: 24)
        try sendShellRequest(channel: channel)
        channel.embeddedEventLoop.run()

        let bytes = ByteBuffer(string: "hello\n")
        try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(bytes)))
        channel.embeddedEventLoop.run()

        // EchoStream forwards inbound bytes back out via its
        // inboundBytes AsyncStream; that turns into a writeOutbound on
        // the channel.
        let outbound: SSHChannelData? = try channel.readOutbound()
        XCTAssertNotNil(outbound)
        if case let .byteBuffer(buf) = outbound!.data {
            XCTAssertEqual(buf.getString(at: 0, length: buf.readableBytes), "hello\n")
        } else {
            XCTFail("expected byteBuffer outbound")
        }
    }

    // MARK: - window-change

    /// window-change channel request forwards cols/rows to
    /// stream.resize().
    func testWindowChangeForwardsToStream() throws {
        let stream = RecordingResizeStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let channel = EmbeddedChannel()
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        try channel.pipeline.syncOperations.addHandler(handler)

        try sendEnvRequest(channel: channel, name: "GRAFTTY_SESSION", value: "alpha")
        try sendPtyRequest(channel: channel, term: "xterm", cols: 80, rows: 24)
        try sendShellRequest(channel: channel)
        channel.embeddedEventLoop.run()

        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: 120,
            terminalRowHeight: 40,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        channel.pipeline.fireUserInboundEventTriggered(event)
        channel.embeddedEventLoop.run()

        XCTAssertEqual(stream.lastResize?.cols, 120)
        XCTAssertEqual(stream.lastResize?.rows, 40)
    }

    // MARK: - close

    /// Channel close (channelInactive) calls stream.close().
    func testChannelCloseClosesStream() throws {
        let stream = ClosableStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let channel = EmbeddedChannel()
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        try channel.pipeline.syncOperations.addHandler(handler)

        try sendEnvRequest(channel: channel, name: "GRAFTTY_SESSION", value: "alpha")
        try sendPtyRequest(channel: channel, term: "xterm", cols: 80, rows: 24)
        try sendShellRequest(channel: channel)
        channel.embeddedEventLoop.run()

        _ = try channel.finish()
        channel.embeddedEventLoop.run()

        XCTAssertTrue(stream.didClose)
    }

    // MARK: - streamFactory throws

    /// If streamFactory throws (e.g. zmx not running, session not
    /// found), the handler sends exit-status: 1 and closes the channel.
    func testStreamFactoryThrowsSendsExitStatusAndCloses() throws {
        let factory = RecordingStreamFactory(returning: .failure(FactoryError.notFound))
        let channel = EmbeddedChannel()
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        try channel.pipeline.syncOperations.addHandler(handler)

        try sendEnvRequest(channel: channel, name: "GRAFTTY_SESSION", value: "missing")
        try sendPtyRequest(channel: channel, term: "xterm", cols: 80, rows: 24)
        try sendShellRequest(channel: channel)
        channel.embeddedEventLoop.run()

        // exit-status is an outbound channel-request event. Drain
        // outbound and look for it.
        var sawExitStatus = false
        while let event = try channel.readOutbound(as: SSHChannelRequestEvent.ExitStatus.self) {
            if event.exitStatus == 1 { sawExitStatus = true }
        }
        XCTAssertTrue(sawExitStatus, "expected exit-status: 1 outbound after factory throw")
    }

    // MARK: - helpers

    private func sendEnvRequest(channel: EmbeddedChannel, name: String, value: String) throws {
        let event = SSHChannelRequestEvent.EnvironmentRequest(
            wantReply: true,
            name: name,
            value: value
        )
        channel.pipeline.fireUserInboundEventTriggered(event)
    }

    private func sendPtyRequest(channel: EmbeddedChannel, term: String, cols: UInt16, rows: UInt16) throws {
        let event = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: UInt32(cols),
            terminalRowHeight: UInt32(rows),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        channel.pipeline.fireUserInboundEventTriggered(event)
    }

    private func sendShellRequest(channel: EmbeddedChannel) throws {
        let event = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        channel.pipeline.fireUserInboundEventTriggered(event)
    }
}

// MARK: - Test fakes

private enum FactoryError: Error { case notFound }

private final class RecordingStreamFactory: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var received: [String] = []
    private let result: Result<TerminalByteStream, Error>

    init(returning result: Result<TerminalByteStream, Error>) {
        self.result = result
    }

    var callable: @Sendable (String) async throws -> TerminalByteStream {
        return { [self] name in
            self.lock.lock()
            self.received.append(name)
            self.lock.unlock()
            return try self.result.get()
        }
    }
}

/// Echoes inbound bytes straight back to the caller via inboundBytes.
private final class EchoStream: TerminalByteStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>

    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func send(_ bytes: Data) async throws {
        continuation.yield(bytes)
    }

    func close() async {
        continuation.finish()
    }
}

/// Records resize calls without echoing bytes.
private final class RecordingResizeStream: TerminalByteStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>
    private let lock = NSLock()
    private(set) var lastResize: (cols: Int, rows: Int)?

    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func send(_ bytes: Data) async throws {}
    func close() async { continuation.finish() }

    func resize(cols: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        lastResize = (cols, rows)
    }
}

/// Records close calls.
private final class ClosableStream: TerminalByteStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>
    private let lock = NSLock()
    private(set) var didClose = false

    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func send(_ bytes: Data) async throws {}

    func close() async {
        lock.lock(); defer { lock.unlock() }
        didClose = true
        continuation.finish()
    }
}
```

Note on the `resize` method on `TerminalByteStream`: the existing protocol in `Sources/GrafttyKit/Remote/TerminalByteStream.swift` does NOT have a `resize(cols:rows:)` method yet. R4 adds it as a default-no-op protocol requirement so existing fakes don't break. See Step 2 below.

- [ ] **Step 2: Extend `TerminalByteStream` protocol with resize**

Modify `Sources/GrafttyKit/Remote/TerminalByteStream.swift` and the mirror at `Sources/GrafttyMobileKit/Remote/TerminalByteStream.swift`. Add a default-implemented `resize(cols:rows:)` method:

```swift
public protocol TerminalByteStream: Sendable {
    func send(_ bytes: Data) async throws
    var inboundBytes: AsyncStream<Data> { get }
    func close() async

    /// Adjust the underlying PTY's window size. Default implementation
    /// is a no-op so existing conformers don't break; the production
    /// `zmx attach` Process conformer overrides this to invoke
    /// `ioctl(TIOCSWINSZ, ...)` (or equivalent).
    func resize(cols: Int, rows: Int) async
}

public extension TerminalByteStream {
    func resize(cols: Int, rows: Int) async {}
}
```

Apply the same edit to the `GrafttyMobileKit` mirror (which is `#if canImport(UIKit)`-guarded — keep the guard).

- [ ] **Step 3: Run the tests; expect them to fail because TerminalSessionHandler doesn't exist yet**

Run: `swift test --filter TerminalSessionHandlerTests`
Expected: compile failure on `import GrafttyHostAgent` line referencing `TerminalSessionHandler` (type not found).

This is the RED step of TDD.

- [ ] **Step 4: Implement `TerminalSessionHandler`**

Create `Sources/GrafttyHostAgent/SSH/Channels/TerminalSessionHandler.swift`:

```swift
import Foundation
import GrafttyKit
import NIOCore
import NIOSSH

/// Server-side SSH channel handler for graftty's terminal session
/// channel. Installs on an inbound SSH session child channel and:
///
///   1. Collects `env GRAFTTY_SESSION=<name>` and `pty-req` channel
///      requests as they arrive.
///   2. On `shell`, calls the injected `streamFactory(name)` to obtain
///      a `TerminalByteStream` (which in production wraps a
///      `Process` spawning `zmx attach <name>`).
///   3. Bridges bytes both ways: inbound `SSHChannelData` -> `stream.send`;
///      `stream.inboundBytes` -> outbound `SSHChannelData`.
///   4. Forwards `window-change` channel requests to `stream.resize`.
///   5. On channel close, calls `stream.close()` — which terminates the
///      `zmx attach` Process. The user's shell survives because it
///      runs in the zmx daemon, attached/detached transparently.
///   6. If `streamFactory` throws, sends `exit-status: 1` and closes
///      the channel.
public final class TerminalSessionHandler: ChannelInboundHandler {
    public typealias InboundIn = SSHChannelData
    public typealias OutboundOut = SSHChannelData

    private let streamFactory: @Sendable (String) async throws -> TerminalByteStream
    private var envSessionName: String?
    private var ptyAccepted = false
    private var stream: TerminalByteStream?
    private var inboundForwardingTask: Task<Void, Never>?

    public init(streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream) {
        self.streamFactory = streamFactory
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard stream != nil else {
            // Bytes arrived before `shell` completed attach; drop them.
            // Real clients never do this — SSH state machine prevents
            // shell-before-data — but be defensive.
            return
        }
        let channelData = unwrapInboundIn(data)
        guard case let .byteBuffer(buf) = channelData.data else { return }
        var view = buf
        guard let bytes = view.readBytes(length: view.readableBytes) else { return }
        let snapshot = stream
        Task { [snapshot] in
            try? await snapshot?.send(Data(bytes))
        }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let envEvent as SSHChannelRequestEvent.EnvironmentRequest:
            if envEvent.name == "GRAFTTY_SESSION" {
                envSessionName = envEvent.value
            }
            // Acknowledge the env request if a reply was requested.
            // (Other env names are accepted silently — no-op.)
            if envEvent.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }

        case let ptyEvent as SSHChannelRequestEvent.PseudoTerminalRequest:
            // Accept any pty-req. We don't capture initial cols/rows
            // here because the stream isn't attached yet; the client
            // re-sends window-change after shell completes if needed.
            ptyAccepted = true
            if ptyEvent.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }

        case let shellEvent as SSHChannelRequestEvent.ShellRequest:
            guard let name = envSessionName else {
                // No GRAFTTY_SESSION env — we have nothing to attach to.
                if shellEvent.wantReply {
                    context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                }
                context.close(promise: nil)
                return
            }
            attach(context: context, sessionName: name, wantReply: shellEvent.wantReply)

        case let winEvent as SSHChannelRequestEvent.WindowChangeRequest:
            guard let snapshot = stream else { return }
            let cols = Int(winEvent.terminalCharacterWidth)
            let rows = Int(winEvent.terminalRowHeight)
            Task { [snapshot] in
                await snapshot.resize(cols: cols, rows: rows)
            }

        default:
            // Other channel-request events (exec, signal, exit-*) are
            // not used by graftty's iPad client; ignore.
            break
        }
    }

    public func channelInactive(context: ChannelHandlerContext) {
        inboundForwardingTask?.cancel()
        let snapshot = stream
        stream = nil
        Task { [snapshot] in
            await snapshot?.close()
        }
        context.fireChannelInactive()
    }

    private func attach(context: ChannelHandlerContext, sessionName: String, wantReply: Bool) {
        let factory = streamFactory
        let channel = context.channel
        let loop = context.eventLoop

        Task { [weak self] in
            do {
                let stream = try await factory(sessionName)
                try await loop.submit { [weak self] in
                    guard let self else { return }
                    self.stream = stream
                    if wantReply {
                        context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
                    }
                    self.startInboundForwarding(stream: stream, channel: channel, loop: loop)
                }.get()
            } catch {
                try? await loop.submit {
                    if wantReply {
                        context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                    }
                    let exit = SSHChannelRequestEvent.ExitStatus(exitStatus: 1)
                    context.triggerUserOutboundEvent(exit, promise: nil)
                    context.close(promise: nil)
                }.get()
            }
        }
    }

    private func startInboundForwarding(stream: TerminalByteStream, channel: Channel, loop: EventLoop) {
        let task = Task {
            for await chunk in stream.inboundBytes {
                let buffer = channel.allocator.buffer(bytes: chunk)
                let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
                _ = try? await loop.submit {
                    channel.writeAndFlush(NIOAny(data), promise: nil)
                }.get()
            }
        }
        inboundForwardingTask = task
    }
}
```

- [ ] **Step 5: Run the tests; expect them to pass**

Run: `swift test --filter TerminalSessionHandlerTests`
Expected: all 5 tests pass.

If a test fails, fix the handler — not the test. (The tests express R4's spec contract.)

- [ ] **Step 6: Run the full Mac test suite**

Run: `swift test 2>&1 | tail -5`
Expected: no regressions in pre-existing tests. The PollingTickerTests / WEB-4.10 flakes documented in earlier memory are acceptable if they appear once.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyHostAgent/SSH/Channels/TerminalSessionHandler.swift \
        Sources/GrafttyKit/Remote/TerminalByteStream.swift \
        Sources/GrafttyMobileKit/Remote/TerminalByteStream.swift \
        Tests/GrafttyTests/Remote/SSH/TerminalSessionHandlerTests.swift
git commit -m "$(cat <<'EOF'
feat(R4): TerminalSessionHandler — server-side SSH session channel

Reads GRAFTTY_SESSION env, accepts pty-req, on shell invokes injected
streamFactory(name) to attach. Bridges bytes both ways. Forwards
window-change. Channel close kills the stream (which terminates zmx
attach in production; underlying shell survives in zmx daemon).
streamFactory throws -> exit-status: 1 + close.

Adds `resize(cols:rows:)` to TerminalByteStream as a default-no-op
protocol method so existing fakes keep working.

5 XCTest cases against an EmbeddedChannel cover: env+pty+shell -> attach,
shell-without-env rejection, bytes round-trip, window-change forwarding,
channel close, factory-throws.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `TerminalSessionClient` (mobile-side, `WebSocketClient` conformer)

**Files:**
- Create: `Sources/GrafttyMobileKit/Remote/SSH/Channels/TerminalSessionClient.swift`

The client side: opens an SSH session channel via the parent `NIOSSHHandler`, sends `env GRAFTTY_SESSION=<name>` → `pty-req` → `shell`, then bridges bytes both ways. Conforms to `WebSocketClient` so `SessionClient` consumes it unchanged.

- [ ] **Step 1: Implement the client**

Create `Sources/GrafttyMobileKit/Remote/SSH/Channels/TerminalSessionClient.swift`:

```swift
#if canImport(UIKit)
import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH

/// Mobile-side `WebSocketClient` conformer that carries graftty terminal
/// I/O over an SSH session child channel.
///
/// Lifecycle:
///   1. `connect()` opens an SSH child channel of type `.session` via
///      the parent `NIOSSHHandler`, sends `env GRAFTTY_SESSION=<name>`,
///      `pty-req`, `shell`. Resolves when shell is accepted.
///   2. `send(.binary(data))` writes the bytes as `SSHChannelData` to
///      the channel.
///   3. `receive()` returns the next `.binary(Data)` from an internal
///      buffer (populated by the inbound handler).
///   4. `resize(cols:rows:)` sends an SSH `window-change` channel
///      request.
///   5. `close()` closes the SSH child channel; the server-side handler
///      sees `channelInactive` and tears down the stream.
public final class TerminalSessionClient: WebSocketClient, @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case notConnected
        case channelClosed
        case openFailed(any Error)
    }

    private let parentChannel: Channel
    private let parentHandler: NIOSSHHandler
    private let sessionName: String
    private let lock = NIOLock()
    private var childChannel: Channel?
    private var receiveBuffer: [Data] = []
    private var pendingReceivers: [CheckedContinuation<WebSocketFrame, Error>] = []
    private var didFailReceive: (any Error)?
    private var closed = false

    public init(parentChannel: Channel, parentHandler: NIOSSHHandler, sessionName: String) {
        self.parentChannel = parentChannel
        self.parentHandler = parentHandler
        self.sessionName = sessionName
    }

    /// Opens the SSH session child channel and completes env+pty+shell.
    public func connect() async throws {
        let promise = parentChannel.eventLoop.makePromise(of: Channel.self)
        parentHandler.createChannel(promise, channelType: .session) { [weak self] child, _ in
            guard let self else {
                return child.eventLoop.makeFailedFuture(ClientError.notConnected)
            }
            return child.pipeline.addHandler(InboundRelay(owner: self))
        }
        let child: Channel
        do {
            child = try await promise.futureResult.get()
        } catch {
            throw ClientError.openFailed(error)
        }
        try await Self.sendEnv(channel: child, name: "GRAFTTY_SESSION", value: sessionName)
        try await Self.sendPty(channel: child, term: "xterm-256color", cols: 80, rows: 24)
        try await Self.sendShell(channel: child)

        lock.withLock {
            childChannel = child
        }

        // Watch for child-channel close so receivers waiting in
        // `receive()` see channelClosed instead of hanging.
        child.closeFuture.whenComplete { [weak self] _ in
            self?.handleChildClose()
        }
    }

    public func send(_ frame: WebSocketFrame) async throws {
        let child = lock.withLock { childChannel }
        guard let child else { throw ClientError.notConnected }
        let bytes: Data
        switch frame {
        case .binary(let data): bytes = data
        case .text(let s): bytes = Data(s.utf8)
        }
        let buffer = child.allocator.buffer(bytes: bytes)
        let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        try await child.writeAndFlush(NIOAny(data)).get()
    }

    public func receive() async throws -> WebSocketFrame {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WebSocketFrame, Error>) in
            lock.withLock {
                if let error = didFailReceive {
                    cont.resume(throwing: error)
                    return
                }
                if !receiveBuffer.isEmpty {
                    let next = receiveBuffer.removeFirst()
                    cont.resume(returning: .binary(next))
                    return
                }
                if closed {
                    cont.resume(throwing: ClientError.channelClosed)
                    return
                }
                pendingReceivers.append(cont)
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

    public func resize(cols: Int, rows: Int) async throws {
        let child = lock.withLock { childChannel }
        guard let child else { throw ClientError.notConnected }
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: UInt32(cols),
            terminalRowHeight: UInt32(rows),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        try await child.triggerUserOutboundEvent(event).get()
    }

    // MARK: - Inbound bytes from the SSH channel

    fileprivate func deliverInbound(_ data: Data) {
        lock.withLock {
            if let next = pendingReceivers.first {
                pendingReceivers.removeFirst()
                next.resume(returning: .binary(data))
            } else {
                receiveBuffer.append(data)
            }
        }
    }

    fileprivate func handleChildClose() {
        let toResume: [CheckedContinuation<WebSocketFrame, Error>] = lock.withLock {
            let pending = pendingReceivers
            pendingReceivers.removeAll()
            closed = true
            didFailReceive = ClientError.channelClosed
            return pending
        }
        for cont in toResume {
            cont.resume(throwing: ClientError.channelClosed)
        }
    }

    // MARK: - Channel-request senders

    private static func sendEnv(channel: Channel, name: String, value: String) async throws {
        let event = SSHChannelRequestEvent.EnvironmentRequest(
            wantReply: true,
            name: name,
            value: value
        )
        try await channel.triggerUserOutboundEvent(event).get()
    }

    private static func sendPty(channel: Channel, term: String, cols: UInt16, rows: UInt16) async throws {
        let event = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: UInt32(cols),
            terminalRowHeight: UInt32(rows),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        try await channel.triggerUserOutboundEvent(event).get()
    }

    private static func sendShell(channel: Channel) async throws {
        let event = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        try await channel.triggerUserOutboundEvent(event).get()
    }
}

/// Inbound relay installed on the SSH child channel. Forwards inbound
/// `SSHChannelData` to the owning `TerminalSessionClient`.
private final class InboundRelay: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    weak var owner: TerminalSessionClient?

    init(owner: TerminalSessionClient) {
        self.owner = owner
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case let .byteBuffer(buf) = channelData.data else { return }
        var view = buf
        guard let bytes = view.readBytes(length: view.readableBytes) else { return }
        owner?.deliverInbound(Data(bytes))
    }
}
#endif
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: clean build.

No unit test for this file — its behavior is covered end-to-end by Task 8's loopback test. A standalone unit test would need an embedded NIOSSHHandler client and have low marginal coverage value.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyMobileKit/Remote/SSH/Channels/TerminalSessionClient.swift
git commit -m "$(cat <<'EOF'
feat(R4): TerminalSessionClient — mobile-side WebSocketClient over SSH

Opens an SSH session child channel via the parent NIOSSHHandler, sends
env GRAFTTY_SESSION=<name> + pty-req + shell, bridges bytes both ways.
Conforms to WebSocketClient so SessionClient consumes it unchanged.
resize(cols:rows:) issues an SSH window-change channel request.

No direct unit test — end-to-end behavior is covered by R4's loopback
test (added in a later commit).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Wire SSH into `WebRTCHostAgent`

**Files:**
- Modify: `Sources/GrafttyHostAgent/WebRTCHostAgent.swift`

After the DataChannel opens, install R3's `SSHServerSetup` with a child-channel initializer that creates a `TerminalSessionHandler(streamFactory:)`. Take `streamFactory`, `hostKey`, `trustedPeerStore` as new init parameters.

- [ ] **Step 1: Add new init parameters**

Open `Sources/GrafttyHostAgent/WebRTCHostAgent.swift`. Find the `public init()` block (around line 45). Replace with:

```swift
public init(
    hostKey: Curve25519.Signing.PrivateKey,
    trustedPeerStore: TrustedPeerStore,
    streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream
) {
    // SSL and codec subsystems are process-wide; initialize once.
    Self.initializeWebRTC()
    self.factory = RTCPeerConnectionFactory()
    self.dataChannelDelegate = DataChannelDelegate()
    self.hostKey = hostKey
    self.trustedPeerStore = trustedPeerStore
    self.streamFactory = streamFactory
}
```

Add the corresponding stored properties at the top of the actor:

```swift
private let hostKey: Curve25519.Signing.PrivateKey
private let trustedPeerStore: TrustedPeerStore
private let streamFactory: @Sendable (String) async throws -> TerminalByteStream
private var sshTransport: SSHNIOTransport?
```

Also add the necessary imports near the top of the file:

```swift
import CryptoKit
import NIOCore
import NIOSSH
```

- [ ] **Step 2: Install SSH after DataChannel opens**

Find the `dataChannelDelegate.onOpen = { [weak self] in ... }` closure (around line 167). Replace its body to install the SSH transport:

```swift
dataChannelDelegate.onOpen = { [weak self] in
    Task { [weak self] in
        guard let self else { return }
        await self.installSSHHandler()
    }
}
```

Add a new method to the actor:

```swift
private func installSSHHandler() async {
    guard let dc = dataChannel else { return }
    let transport = SSHNIOTransport(dataChannel: dc)
    let factory = streamFactory
    do {
        try await transport.eventLoop.submit { [hostKey, trustedPeerStore] in
            let handler = SSHServerSetup.makeHandler(
                hostKey: hostKey,
                trustedPeerStore: trustedPeerStore,
                allocator: transport.channel.allocator,
                inboundChildChannelInitializer: { child, channelType in
                    guard case .session = channelType else {
                        return child.eventLoop.makeFailedFuture(WebRTCHostAgentError.unsupportedChannelType)
                    }
                    return child.eventLoop.makeCompletedFuture {
                        let sessionHandler = TerminalSessionHandler(streamFactory: factory)
                        try child.pipeline.syncOperations.addHandler(sessionHandler)
                    }
                }
            )
            try transport.channel.pipeline.syncOperations.addHandler(handler)
        }.get()
        try await transport.start()
        self.sshTransport = transport
        self.state = .connected
    } catch {
        self.state = .failed(reason: "SSH install failed: \(error)")
    }
}

private enum WebRTCHostAgentError: Error {
    case unsupportedChannelType
}
```

The `state = .connected` line replaces whatever transition currently happens on DataChannel open. Audit the existing transition logic in `dataChannelDelegate.onOpen` and remove the old `state = ...` set since `installSSHHandler` now owns that transition.

- [ ] **Step 3: Close SSH on teardown**

Find the `public func close()` method. Modify to close the SSH transport before the DataChannel:

```swift
public func close() {
    if let transport = sshTransport {
        Task { await transport.close() }
        sshTransport = nil
    }
    state = .closed
    if let pc = peerConnection {
        pc.close()
        peerConnection = nil
    }
    dataChannel?.close()
    dataChannel = nil
}
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build`
Expected: clean build. If `Graftty/GrafttyApp.swift` (the only known caller of `WebRTCHostAgent()`) breaks because of the new required parameters, that's expected — Task 6 fixes it. The build target `GrafttyHostAgent` itself should still build cleanly in isolation. Run `swift build --target GrafttyHostAgent` to verify.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyHostAgent/WebRTCHostAgent.swift
git commit -m "$(cat <<'EOF'
feat(R4): wire SSH server into WebRTCHostAgent

After DataChannel opens, install R3's SSHServerSetup with a child-channel
initializer that creates a TerminalSessionHandler(streamFactory:) for each
inbound SSH session channel. New init params: hostKey, trustedPeerStore,
streamFactory.

The Graftty target temporarily fails to build — it constructs WebRTCHostAgent()
with no args. Task 6 of R4 fixes that by passing the new required params.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Wire SSH into `RemoteHostConnection`

**Files:**
- Modify: `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift`

Mirror of Task 4 on the mobile side. After DataChannel opens, install `SSHClientSetup`. Expose `openTerminalSession(sessionName:) async throws -> TerminalSessionClient`.

- [ ] **Step 1: Add new init parameters and properties**

Open `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift`. Find `public init()` (line 84). Replace:

```swift
public init(
    clientKey: Curve25519.Signing.PrivateKey,
    expectedHostFingerprint: RemoteIdentityFingerprint
) {
    Self.initializeWebRTC()
    self.factory = RTCPeerConnectionFactory()
    self.delegate = PeerConnectionDelegate()
    self.dataChannelDelegate = DataChannelDelegate()
    self.clientKey = clientKey
    self.expectedHostFingerprint = expectedHostFingerprint
}
```

Add stored properties (after the existing `private var dataChannel: RTCDataChannel?`):

```swift
private let clientKey: Curve25519.Signing.PrivateKey
private let expectedHostFingerprint: RemoteIdentityFingerprint
private var sshTransport: SSHNIOTransport?
private var sshHandler: NIOSSHHandler?
```

Add imports near the top:

```swift
import CryptoKit
import NIOCore
import NIOSSH
```

- [ ] **Step 2: Install SSH after DataChannel opens**

Find the `dataChannelDelegate.onOpen = { [weak self] in ... }` (around line 137-ish; look for the existing `openContinuation?.resume()` pattern). Replace the body so the SSH install happens before the open continuation resumes:

```swift
dataChannelDelegate.onOpen = { [weak self] in
    Task { [weak self] in
        guard let self else { return }
        await self.installSSHHandlerAndResume()
    }
}
```

Add the install method to the actor:

```swift
private func installSSHHandlerAndResume() async {
    guard let dc = dataChannel else { return }
    let transport = SSHNIOTransport(dataChannel: dc)
    do {
        let handler: NIOSSHHandler = try await transport.eventLoop.submit { [clientKey, expectedHostFingerprint] in
            let h = SSHClientSetup.makeHandler(
                clientKey: clientKey,
                expectedHostFingerprint: expectedHostFingerprint,
                allocator: transport.channel.allocator
            )
            try transport.channel.pipeline.syncOperations.addHandler(h)
            return h
        }.get()
        try await transport.start()
        self.sshTransport = transport
        self.sshHandler = handler
        self.state = .connected
        self.openContinuation?.resume(returning: ())
        self.openContinuation = nil
    } catch {
        self.state = .failed(reason: "SSH handshake failed: \(error)")
        self.openContinuation?.resume(throwing: error)
        self.openContinuation = nil
    }
}
```

- [ ] **Step 3: Expose `openTerminalSession`**

Add a new public method to the actor:

```swift
public func openTerminalSession(sessionName: String) async throws -> TerminalSessionClient {
    guard
        let transport = sshTransport,
        let handler = sshHandler
    else {
        throw ConnectionError.notConnected
    }
    let client = TerminalSessionClient(
        parentChannel: transport.channel,
        parentHandler: handler,
        sessionName: sessionName
    )
    try await client.connect()
    return client
}
```

If `ConnectionError.notConnected` doesn't already exist on the enum, add it:

```swift
public enum ConnectionError: Error, Sendable {
    case notConnected
    // ... existing cases
}
```

- [ ] **Step 4: Close SSH on teardown**

Find `public func close()` (around line 257). Modify:

```swift
public func close() {
    if let transport = sshTransport {
        Task { await transport.close() }
        sshTransport = nil
        sshHandler = nil
    }
    state = .closed
    // ... existing close logic for peerConnection, dataChannel
}
```

- [ ] **Step 5: Verify it compiles**

Run: `swift build --target GrafttyMobileKit`
Expected: clean. `GrafttyMobileKit` is UIKit-guarded, so the swift CLI may need `--triple` overrides. If the build cannot succeed under the `swift` CLI, check the `xcodebuild` invocation in Task 8's step 5 instead — that's the canonical iOS build path.

Tip: a faster local check is `xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -20`.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift
git commit -m "$(cat <<'EOF'
feat(R4): wire SSH client into RemoteHostConnection

After DataChannel opens, install R3's SSHClientSetup. New init params:
clientKey, expectedHostFingerprint. New public method
openTerminalSession(sessionName:) returns a TerminalSessionClient ready
for SessionClient to consume.

Loopback test wiring (Task 8) updates the existing RemoteHostConnection
test fixtures to pass the new init parameters.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Inject `zmx attach` factory in `GrafttyApp.swift`

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`

The Mac app instantiates `WebRTCHostAgent`. Pass a `streamFactory` closure that spawns `zmx attach <sessionName>` as a `Process` and returns a `TerminalByteStream` wrapping its stdio. Copy the spawn logic from `WebSession.start()` — don't extract.

- [ ] **Step 1: Locate WebRTCHostAgent construction in GrafttyApp**

Run: `grep -n "WebRTCHostAgent()" Sources/Graftty/GrafttyApp.swift`
Expected: one or two matches. If zero, the host agent construction may be elsewhere — try `grep -rn "WebRTCHostAgent(" Sources/Graftty Apps/`.

- [ ] **Step 2: Add the streamFactory closure and rewire construction**

Replace each `WebRTCHostAgent()` construction with the three-parameter form. The closure spawns `zmx attach`:

```swift
let hostAgent = WebRTCHostAgent(
    hostKey: try hostIdentityStore.loadOrCreate(),
    trustedPeerStore: trustedPeerStore,
    streamFactory: { sessionName in
        return try ZmxAttachStream(
            zmxExecutable: zmxExecutable,
            zmxDir: zmxDir,
            sessionName: sessionName,
            workingDirectory: workingDirectoryResolver?(sessionName)
        )
    }
)
```

(`hostIdentityStore`, `trustedPeerStore`, `zmxExecutable`, `zmxDir`, `workingDirectoryResolver` are already wired through the app — find their existing construction sites and reference them. They're typically built up alongside `WebServerController`.)

- [ ] **Step 3: Create `ZmxAttachStream`**

Add a new helper type to `Sources/Graftty/Remote/ZmxAttachStream.swift` (create the `Remote` directory if needed). This is a copy of the relevant bits of `WebSession.start()` — duplication is intentional per R4's design.

```swift
import Foundation
import GrafttyKit

/// `TerminalByteStream` conformer that wraps a `Process` running
/// `zmx attach <sessionName>`. Inbound bytes (stdout from the zmx
/// attach Process) are emitted on the AsyncStream; `send()` writes to
/// stdin; `close()` terminates the Process.
///
/// Lifecycle: the underlying user shell runs in the zmx daemon, not
/// in this Process. Killing the Process detaches the view without
/// affecting the shell. This is the same model used by
/// `Graftty.Web.WebServer.WebSession`; duplication is intentional
/// for R4 — R6 consolidates after `/ws` deletion.
final class ZmxAttachStream: TerminalByteStream, @unchecked Sendable {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>

    init(
        zmxExecutable: URL,
        zmxDir: URL,
        sessionName: String,
        workingDirectory: URL?
    ) throws {
        let process = Process()
        process.executableURL = zmxExecutable
        process.arguments = ["attach", sessionName]
        var env = ProcessInfo.processInfo.environment
        env["ZMX_DIR"] = zmxDir.path
        process.environment = env
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        self.process = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout

        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont

        stdout.fileHandleForReading.readabilityHandler = { [continuation = self.continuation] handle in
            let data = handle.availableData
            if data.isEmpty {
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }

        try process.run()
    }

    func send(_ bytes: Data) async throws {
        try stdinPipe.fileHandleForWriting.write(contentsOf: bytes)
    }

    func close() async {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        continuation.finish()
    }

    // `resize(cols:rows:)` uses the default-no-op protocol implementation
    // for R4. R6 (or a follow-up) wires `ioctl(TIOCSWINSZ)` on the master
    // PTY — see the equivalent path in `WebSession`. R4 ships without
    // this because libghostty client-side resize plus the next attach's
    // env defaults are enough to keep dimensions roughly correct.
}
```

- [ ] **Step 4: Verify the full Mac app builds**

Run: `swift build`
Expected: clean. The Task 4 build break ("WebRTCHostAgent constructor changed") should be resolved by this task's wiring.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift Sources/Graftty/Remote/ZmxAttachStream.swift
git commit -m "$(cat <<'EOF'
feat(R4): inject zmx-attach factory into WebRTCHostAgent

GrafttyApp wires hostKey + trustedPeerStore + a streamFactory closure
that returns a ZmxAttachStream (Process spawning `zmx attach <name>`).

ZmxAttachStream is a TerminalByteStream conformer that mirrors
WebServer.WebSession's Process+Pipe setup. Intentional duplication for
R4; R6 consolidates after /ws deletion. resize() uses the default no-op
for now; ioctl TIOCSWINSZ plumbing is deferred.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Wire `SessionClient.live` to accept `RemoteHostConnection?`

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift`
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift`

`SessionClient.live(baseURL:sessionName:role:)` gains a `remoteHost: RemoteHostConnection?` parameter. When present, the `webSocketFactory` returns `try await remoteHost.openTerminalSession(sessionName:)`. When nil, the existing `URLSessionWebSocketClient` path runs.

- [ ] **Step 1: Update `SessionClient.live`**

Open `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift`. Find the `static func live(...)` method (around line 40). Replace:

```swift
static func live(
    baseURL: URL,
    sessionName: String,
    role: Role = .fullscreen,
    remoteHost: RemoteHostConnection? = nil
) -> SessionClient {
    SessionClient(
        sessionName: sessionName,
        webSocketFactory: {
            if let remoteHost {
                let client = try await remoteHost.openTerminalSession(sessionName: sessionName)
                return client
            }
            let wsURL = RootView.makeWebSocketURL(base: baseURL, session: sessionName)
            return URLSessionWebSocketClient(url: wsURL)
        },
        idleThreshold: role == .preview ? previewIdleThreshold : fullscreenIdleThreshold,
        role: role
    )
}
```

Wait — `webSocketFactory` is currently a non-throwing closure (per its declaration in `SessionClient.init`). Check the signature first.

Run: `grep -n "webSocketFactory" Sources/GrafttyMobileKit/Session/SessionClient.swift | head -5`

If the existing factory signature is `@Sendable () -> WebSocketClient` (synchronous, non-throwing), we have to convert it to `@Sendable () async throws -> WebSocketClient` because opening an SSH child channel is async + throwing.

- [ ] **Step 2: Update `SessionClient`'s factory signature if needed**

If the signature is sync/non-throwing, change it to async-throwing:

```swift
// In Sources/GrafttyMobileKit/Session/SessionClient.swift
nonisolated private let webSocketFactory: @Sendable () async throws -> WebSocketClient

public init(
    sessionName: String,
    webSocketFactory: @Sendable @escaping () async throws -> WebSocketClient,
    idleThreshold: TimeInterval,
    role: Role
)
```

Then update every internal call site that previously did `ws = webSocketFactory()` to `ws = try await webSocketFactory()`. Trace these with: `grep -n "webSocketFactory()" Sources/GrafttyMobileKit/Session/SessionClient.swift`. Each should already be in an `async` context (the dial/redial paths); wrap in `try` accordingly.

The throwing path needs an error sink. Where the existing code assumed the factory always returned a client, replace with:

```swift
do {
    let client = try await webSocketFactory()
    // existing handling of `client`
} catch {
    // surface as the existing "ws connect failed" state
    state = .failed(reason: String(describing: error))
}
```

(The exact shape depends on how `SessionClient` currently models failure — check the actor's existing error paths.)

- [ ] **Step 3: Wire iPad call sites in `RootView.swift`**

Open `Sources/GrafttyMobileKit/App/RootView.swift`. There are two `SessionClient.live(...)` call sites — find them with: `grep -n "SessionClient.live" Sources/GrafttyMobileKit/App/RootView.swift`.

Both need a `remoteHost:` argument. The iPad has a per-host `RemoteHostConnection` available via the existing host-presence machinery (look for the property holding the active connection — likely on `IPadAppState` or similar). Pass it. iPhone callers pass `nil` (or omit the parameter to use the default).

Add a log when iPad falls back to nil — a wiring regression should be visible:

```swift
let client = SessionClient.live(
    baseURL: step.host.baseURL,
    sessionName: step.sessionName,
    remoteHost: ipadRemoteHostConnection(for: step.host)
)

func ipadRemoteHostConnection(for host: SomeHostType) -> RemoteHostConnection? {
    // Whatever the existing iPad accessor is. If it returns nil on
    // iPad, that's a wiring regression — log it so console catches it.
    let conn = currentRemoteHostConnection(for: host)
    if conn == nil, isIpad {
        Logger.shared.warning("R4 wiring regression: iPad has no RemoteHostConnection for \(host.id); falling back to /ws")
    }
    return conn
}
```

(Adapt `isIpad`, `Logger.shared`, and `currentRemoteHostConnection(for:)` to whatever the existing iPad code uses. If the iPad presently has no `RemoteHostConnection` accessor at all, that's a Task 7 sub-task: add one to `IPadAppState` keyed on `HostID`.)

- [ ] **Step 4: Build the iOS target**

Run:
```bash
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build 2>&1 | tail -20
```
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift \
        Sources/GrafttyMobileKit/App/RootView.swift \
        Sources/GrafttyMobileKit/Session/SessionClient.swift
git commit -m "$(cat <<'EOF'
feat(R4): wire SessionClient.live to optional RemoteHostConnection

SessionClient.live(...) gains a `remoteHost: RemoteHostConnection?`
parameter. When non-nil, webSocketFactory returns
remoteHost.openTerminalSession(sessionName:). When nil, the existing
URLSessionWebSocketClient path runs unchanged — iPhone stays on /ws.

SessionClient's webSocketFactory signature changed from sync to
async-throwing because opening an SSH child channel is async + throwing.

RootView passes remoteHost at both call sites. iPad gets the per-host
RemoteHostConnection; iPhone gets nil. Log fires if iPad ends up with
nil — surfaces wiring regressions in console.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `SSHTerminalLoopbackTests` (iOS-only end-to-end)

**Files:**
- Create: `Tests/GrafttyMobileKitTests/Remote/SSH/SSHTerminalLoopbackTests.swift`

Extends R3's `runAuthLoopback` infrastructure. Real `RTCPeerConnection` pair + real SSH stack + fake echoing `TerminalByteStream`. Exercises the full SSH wire (env → pty → shell → bytes both ways → window-change → close).

- [ ] **Step 1: Write the loopback test**

Create the file (mirrors the structure of `SSHAuthLoopbackTests.swift`):

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

/// End-to-end SSH-over-WebRTC terminal-session-channel tests.
///
/// Uses R3's `LoopbackPeer` pattern + real `SSHServerSetup`-equivalent
/// + real `SSHClientSetup` + a fake echoing `TerminalByteStream`. The
/// fake replaces the production `ZmxAttachStream` because iOS Simulator
/// doesn't have host binaries — real `zmx attach` integration is
/// verified at the manual TestFlight gate, not in CI.
///
/// `.serialized` per R3 precedent (one SSH-over-WebRTC stack at a time
/// on the iOS Simulator's resource-constrained runtime).
@Suite(
    "SSH-over-WebRTC terminal channel — env+pty+shell + bytes round-trip (R4)",
    .serialized
)
struct SSHTerminalLoopbackTests {

    /// End-to-end: client opens session channel, sends env+pty+shell,
    /// writes "hi\n", server-side echo stream returns "hi\n".
    @Test(.timeLimit(.minutes(3)))
    func bytesRoundTripThroughTerminalSessionChannel() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(fingerprint: Self.fingerprint(of: clientKey))

        let echoFactory: @Sendable (String) async throws -> TerminalByteStream = { _ in
            EchoStream()
        }

        let received = try await runTerminalLoopback(
            serverKey: serverKey,
            trustedPeers: peerStore,
            clientKey: clientKey,
            expectedHostFingerprint: Self.fingerprint(of: serverKey),
            streamFactory: echoFactory,
            sessionName: "alpha",
            outboundBytes: Data("hi\n".utf8)
        )

        #expect(received == Data("hi\n".utf8))
    }

    /// streamFactory throws -> client `receive()` throws on the next
    /// call (channel closes via exit-status: 1 + close on the server).
    @Test(.timeLimit(.minutes(3)))
    func streamFactoryThrowsClosesChannel() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(fingerprint: Self.fingerprint(of: clientKey))

        let failingFactory: @Sendable (String) async throws -> TerminalByteStream = { _ in
            throw FactoryError.notFound
        }

        await #expect(throws: (any Error).self) {
            _ = try await runTerminalLoopback(
                serverKey: serverKey,
                trustedPeers: peerStore,
                clientKey: clientKey,
                expectedHostFingerprint: Self.fingerprint(of: serverKey),
                streamFactory: failingFactory,
                sessionName: "missing",
                outboundBytes: Data("hi\n".utf8),
                responseDeadline: .seconds(10)
            )
        }
    }

    // MARK: - Loopback driver

    private func runTerminalLoopback(
        serverKey: Curve25519.Signing.PrivateKey,
        trustedPeers: InMemoryTrustedPeerSet,
        clientKey: Curve25519.Signing.PrivateKey,
        expectedHostFingerprint: RemoteIdentityFingerprint,
        streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream,
        sessionName: String,
        outboundBytes: Data,
        responseDeadline: Duration = .seconds(180)
    ) async throws -> Data {
        let offerer = LoopbackPeer(role: .offerer)
        let answerer = LoopbackPeer(role: .answerer)
        let offer = try await offerer.createOffer()
        let answer = try await answerer.accept(offer: offer)
        await offerer.bindIceCandidates(to: answerer)
        await answerer.bindIceCandidates(to: offerer)
        try await offerer.applyAnswer(answer)
        let offererDC = try await offerer.openedDataChannel()
        let answererDC = try await answerer.openedDataChannel()

        let clientTransport = SSHNIOTransport(dataChannel: offererDC)
        let serverTransport = SSHNIOTransport(dataChannel: answererDC)

        // Server: SSHServerSetup-equivalent with TerminalSessionHandler
        // factory for incoming session channels.
        try await serverTransport.eventLoop.submit {
            let serverConfig = SSHServerConfiguration(
                hostKeys: [NIOSSHPrivateKey(ed25519Key: serverKey)],
                userAuthDelegate: TrustSetServerUserAuthDelegate(store: trustedPeers)
            )
            let sshHandler = NIOSSHHandler(
                role: .server(serverConfig),
                allocator: serverTransport.channel.allocator,
                inboundChildChannelInitializer: { childChannel, channelType in
                    guard case .session = channelType else {
                        return childChannel.eventLoop.makeFailedFuture(LoopbackError.unexpectedChannelType)
                    }
                    return childChannel.eventLoop.makeCompletedFuture {
                        let h = TerminalSessionHandler(streamFactory: streamFactory)
                        try childChannel.pipeline.syncOperations.addHandler(h)
                    }
                }
            )
            try serverTransport.channel.pipeline.syncOperations.addHandler(sshHandler)
        }.get()

        // Client: real SSHClientSetup. Capture the handler for
        // TerminalSessionClient to use.
        let handlerPromise = clientTransport.eventLoop.makePromise(of: NIOSSHHandler.self)
        try await clientTransport.eventLoop.submit {
            let h = SSHClientSetup.makeHandler(
                clientKey: clientKey,
                expectedHostFingerprint: expectedHostFingerprint,
                allocator: clientTransport.channel.allocator
            )
            try clientTransport.channel.pipeline.syncOperations.addHandler(h)
            handlerPromise.succeed(h)
        }.get()
        let sshHandler = try await handlerPromise.futureResult.get()

        try await serverTransport.start()
        try await clientTransport.start()

        // Open the terminal session channel via TerminalSessionClient.
        let client = TerminalSessionClient(
            parentChannel: clientTransport.channel,
            parentHandler: sshHandler,
            sessionName: sessionName
        )

        // Belt-and-suspenders deadline (same pattern as R3 — wall-clock
        // Task rather than NIO scheduler).
        let deadlineTask = Task { [client] in
            try? await Task.sleep(for: responseDeadline)
            client.close()
        }
        defer { deadlineTask.cancel() }

        try await client.connect()
        try await client.send(.binary(outboundBytes))

        let frame = try await client.receive()
        let received: Data
        switch frame {
        case .binary(let d): received = d
        case .text(let s): received = Data(s.utf8)
        }

        client.close()
        await clientTransport.close()
        await serverTransport.close()
        await offerer.close()
        await answerer.close()

        return received
    }

    private static func fingerprint(of key: Curve25519.Signing.PrivateKey) -> RemoteIdentityFingerprint {
        let pubkey = try! RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        return RemoteIdentityFingerprint(of: pubkey)
    }
}

// MARK: - Fakes / helpers

private enum FactoryError: Error { case notFound }

private final class EchoStream: TerminalByteStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>

    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func send(_ bytes: Data) async throws {
        continuation.yield(bytes)
    }

    func close() async {
        continuation.finish()
    }
}

// `InMemoryTrustedPeerSet`, `TrustSetServerUserAuthDelegate`, `LoopbackPeer`,
// `LoopbackError`, and the WebRTC helpers are copied verbatim from
// SSHAuthLoopbackTests.swift in the same target. Per R3's precedent
// (and the parent design's "copy don't extract" approach), the dup is
// intentional; consolidation happens post-R6 when a shared fixture
// can replace both files.
//
// Implementer: copy those types from SSHAuthLoopbackTests.swift into
// this file (file-private). Keep their `fileprivate` access so they
// don't collide across both suites.
#endif
```

Per the comment in the file, the implementer copies `InMemoryTrustedPeerSet`, `TrustSetServerUserAuthDelegate`, `LoopbackPeer`, `LoopbackError`, and the WebRTC helpers (`RecordingChannelDelegate`, `RecordingPeerConnectionDelegate`, etc.) from `Tests/GrafttyMobileKitTests/Remote/SSH/SSHAuthLoopbackTests.swift` (around lines 442-700+) into the new file's bottom section. Keep them `fileprivate` to avoid type-name collisions.

- [ ] **Step 2: Run the loopback test on iOS Simulator**

Run:
```bash
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:GrafttyMobileKitTests/SSHTerminalLoopbackTests \
  2>&1 | tail -30
```
Expected: 2 tests pass within their 3-minute time limits each. `bytesRoundTripThroughTerminalSessionChannel` completes in ~10s on healthy CI; `streamFactoryThrowsClosesChannel` should fail within the 10s short deadline (catches the close from `exit-status: 1`).

If the round-trip test hangs, the most likely root cause is the client never receiving the `shell` channel-success ack — debug by adding `print` statements in `TerminalSessionClient.connect()` between the env / pty / shell sends.

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyMobileKitTests/Remote/SSH/SSHTerminalLoopbackTests.swift
git commit -m "$(cat <<'EOF'
test(R4): SSH terminal-channel loopback — env+pty+shell + bytes round-trip

End-to-end test: real RTCPeerConnection pair + real SSHServerSetup-equiv
+ real SSHClientSetup + TerminalSessionHandler + TerminalSessionClient.
Fake echoing TerminalByteStream stands in for ZmxAttachStream because
iOS Simulator can't spawn host processes — real zmx integration is
verified at the manual TestFlight gate.

Two cases:
- bytesRoundTripThroughTerminalSessionChannel: positive baseline
- streamFactoryThrowsClosesChannel: server-side factory throw -> channel
  close + client receive() throws

.serialized + .timeLimit(.minutes(3)) per R3 precedent for iOS CI
variance.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Verification + `/simplify` + PR

**Files:** None (verification only)

- [ ] **Step 1: Full Mac test suite**

Run: `swift test 2>&1 | tail -10`
Expected: all macOS tests pass. The R4 source files compile cleanly. The UIKit-guarded loopback test file is skipped on macOS — that's expected.

If a pre-existing flake fires (PollingTickerTests / WEB-4.10 from prior memory), re-run once.

- [ ] **Step 2: Full iOS Simulator test suite**

Run:
```bash
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test 2>&1 | tail -10
```
Expected: all tests pass. Canonical gate per `feedback_macos_swift_test_misses_uikit_guarded_code`.

- [ ] **Step 3: Verify SPECS.md is clean**

Run: `python3 scripts/generate-specs.py --check`
Expected: zero exit. (R4 adds no specs, so this should be a no-op check.)

- [ ] **Step 4: Audit diff scope**

Run: `git diff main..HEAD --stat`

Expected files changed (approximate):
- `docs/superpowers/specs/2026-05-21-ssh-over-webrtc-design.md` (~1 line)
- `docs/superpowers/specs/2026-05-27-ssh-over-webrtc-phase-4-design.md` (already committed in the spec commit; +1 §7 wording fix)
- `docs/superpowers/plans/2026-05-27-ssh-over-webrtc-r4-terminal-channel.md` (this plan, if committed)
- `Sources/GrafttyHostAgent/SSH/Channels/TerminalSessionHandler.swift` (NEW)
- `Sources/GrafttyHostAgent/WebRTCHostAgent.swift`
- `Sources/GrafttyKit/Remote/TerminalByteStream.swift` (resize default)
- `Sources/GrafttyMobileKit/Remote/SSH/Channels/TerminalSessionClient.swift` (NEW)
- `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift`
- `Sources/GrafttyMobileKit/Remote/TerminalByteStream.swift` (resize default mirror)
- `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift`
- `Sources/GrafttyMobileKit/App/RootView.swift`
- `Sources/GrafttyMobileKit/Session/SessionClient.swift` (factory signature)
- `Sources/Graftty/GrafttyApp.swift`
- `Sources/Graftty/Remote/ZmxAttachStream.swift` (NEW)
- `Tests/GrafttyTests/Remote/SSH/TerminalSessionHandlerTests.swift` (NEW)
- `Tests/GrafttyMobileKitTests/Remote/SSH/SSHTerminalLoopbackTests.swift` (NEW)

No other files should be touched. Specifically: no edits to `ChannelRouter*`, `TerminalChannelHandler*`, `WebSocketBridgeHandler`, or `WebSession` (those land in R5/R6).

- [ ] **Step 5: Run `/simplify` on the cumulative R4 diff**

This step is performed by the orchestrating session, not the subagent. Dispatch the `code-simplifier:code-simplifier` agent against `main..HEAD`. Apply whatever the simplifier suggests as a final commit.

- [ ] **Step 6: Push and open PR**

```bash
git push -u origin ssh-webrtc-r4
gh pr create --title "feat(remote): R4 — terminal session channel (iPad SSH cutover)" --body "$(cat <<'EOF'
## Summary

R4 of the SSH-over-WebRTC sequence. Wires SSH-over-WebRTC into the iPad's
terminal path — **first production WebRTC traffic in graftty.** R2 and R3
added the SSH stack but only exercised it in loopback tests; R4 makes a
real iPad attached to a paired Mac talk to that Mac's PTYs over
`WebRTC DataChannel → SSH session channel → zmx attach`.

iPhone continues using `/ws`. R6 cuts iPhone over and deletes
`/ws` + `ChannelRouter*`.

### What's in R4

- **NEW** `TerminalSessionHandler` (server): reads SSH env `GRAFTTY_SESSION`,
  accepts `pty-req` + `shell`, calls injected `streamFactory(name)`, bridges
  bytes both ways, plumbs `window-change`.
- **NEW** `TerminalSessionClient` (mobile): conforms to `WebSocketClient` so
  `SessionClient` consumes it unchanged.
- **NEW** `ZmxAttachStream` (Mac): `TerminalByteStream` conformer wrapping
  a `Process` running `zmx attach <name>`. Copied (not extracted) from
  `WebSession.start()` per R4's design — R6 consolidates after `/ws` deletion.
- `WebRTCHostAgent` + `RemoteHostConnection` install the R3 SSH layer when the
  DataChannel opens and expose `openTerminalSession(sessionName:)`.
- `SessionClient.live(...)` gains a `remoteHost: RemoteHostConnection?`
  parameter. iPad passes the per-host connection; iPhone passes nil.

### What's NOT in R4

- iPhone (stays on `/ws` until R6)
- `panes-state` / `pane-control` SSH channels (R5)
- `/ws` deletion + `ChannelRouter*` deletion (R6)
- Spec promotions for `REMOTE-2.1`, `REMOTE-3.1`, `REMOTE-5.1` (R6; each must
  hold for both transports before promotion)

### Design docs

- Parent: `docs/superpowers/specs/2026-05-21-ssh-over-webrtc-design.md`
- R4: `docs/superpowers/specs/2026-05-27-ssh-over-webrtc-phase-4-design.md`
- R4 plan: `docs/superpowers/plans/2026-05-27-ssh-over-webrtc-r4-terminal-channel.md`

## Test plan

- [ ] `swift test` green (Mac)
- [ ] `xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 17'` green
- [ ] `/simplify` run on cumulative R4 diff
- [ ] **Manual TestFlight verification (REQUIRED — first production WebRTC traffic):**
  Build Mac app, install on TestFlight iPad, pair, attach to a worktree,
  type a command, confirm output. Loopback test does NOT substitute for
  this step.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review Notes (for the orchestrator)

**Spec coverage check:**
- R4 spec §3 In items 1-9: covered by Tasks 2, 3, 4, 5, 6, 7, 8.
- R4 spec §3 Out items: explicitly NOT addressed (R5/R6 scope).
- R4 spec §4 architecture: implemented by the wiring tasks 4-7.
- R4 spec §5 channel lifecycle: tested in Task 2 (handler unit tests) + Task 8 (end-to-end).
- R4 spec §6 error handling: tested in Task 2 (`testStreamFactoryThrows*`) + Task 8 (`streamFactoryThrowsClosesChannel`).
- R4 spec §7 testing: implemented by Task 2 + Task 8.
- R4 spec §8 spec impact: no promotions; Task 1 fixes the parent-design wording.
- R4 spec §9 risks: each tracked in its corresponding Task.
- R4 spec §10 decisions: each decision is locked into a specific Task.

**Honest acknowledgements:**

1. **Task 7's `SessionClient.webSocketFactory` signature change** is the most invasive part of R4. It changes a sync non-throwing closure to an async-throwing one, which ripples through every caller of the factory. The plan's Step 2 sketches the change but the actual rewiring depends on the existing `SessionClient` actor's failure model — the implementer needs to read `SessionClient.swift` and adapt.

2. **The iPad accessor `currentRemoteHostConnection(for:)` may not exist yet.** Task 7 Step 3 hand-waves at "whatever the existing iPad accessor is." If the iPad hasn't been wiring `RemoteHostConnection` per-host at all (which is likely — the parent design noted production hasn't used WebRTC yet), Task 7 needs a sub-task: add a `RemoteHostConnection` cache to `IPadAppState` keyed on `HostID`, instantiate one per paired host on first iPad-side connect, hand it to `SessionClient.live`. This sub-task adds ~50-100 lines.

3. **`TerminalSessionHandler` is the trickiest piece.** It's an actor-free `ChannelInboundHandler` because NIO pipelines are not actor-friendly. State (`envSessionName`, `ptyAccepted`, `stream`, `inboundForwardingTask`) is event-loop-isolated; mutation happens only inside `channelRead` / `userInboundEventTriggered`, which NIO guarantees run on the channel's event loop. The implementer should NOT add locks around these properties — that would be redundant and risk deadlocks.

4. **The `EchoStream` test fake** uses the protocol's default `resize(cols:rows:)` no-op. The `RecordingResizeStream` fake overrides it. If the implementer finds `resize` isn't being called in Task 2's `testWindowChangeForwardsToStream`, the most likely cause is the handler dispatching `resize` to a Task that the EmbeddedChannel doesn't drain — wrap the assertion in a brief `try await Task.yield(); try await Task.yield()` if needed.

**Type consistency check:**
- `TerminalSessionHandler.streamFactory: @Sendable (String) async throws -> TerminalByteStream` — same shape in all tasks (2, 4, 6, 8).
- `TerminalSessionClient` init: `(parentChannel: Channel, parentHandler: NIOSSHHandler, sessionName: String)` — consistent in Tasks 3, 5, 8.
- `RemoteHostConnection.openTerminalSession(sessionName:) -> TerminalSessionClient` — Tasks 5, 7, 8.
- `SessionClient.live(baseURL:sessionName:role:remoteHost:)` — Tasks 7, then propagated to `RootView` call sites.

**Placeholder scan:**
- No "TBD" / "TODO" / "implement later" anywhere in the plan steps.
- "Whatever the existing iPad accessor is" in Task 7 Step 3 IS a placeholder — but it's an honest "I haven't read this part of the code yet" placeholder, and the self-review notes call it out as a sub-task to add. Acceptable.
- "Adapt `isIpad`, `Logger.shared`" in Task 7 Step 3 is a similar honest placeholder.
