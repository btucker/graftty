# R4 Review Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** Address the 15 findings from the extra-high-effort code review of PR #202 before merge. Mix of correctness bugs (resize broken on SSH path; potential Mac crash) and lifecycle/race issues (double SSH install; un-closed transports on failure).

**Architecture:** 5 task bundles, each landing as one focused commit on `ssh-webrtc-r4`. Each bundle is independently reviewable; together they leave PR #202 ready to merge.

**Tech Stack:** Swift, swift-nio, swift-nio-ssh, NIO actors, WebRTC.

---

## Task 1: Resize plumbing on the SSH path (Finding #1)

**Files:**
- Modify: `Sources/GrafttyMobileKit/Session/WebSocketClient.swift` — add `resize(cols:rows:) async` to protocol with default no-op
- Modify: `Sources/GrafttyMobileKit/Session/WebSocketClient.swift` — `URLSessionWebSocketClient.resize(...)` sends `WebControlEnvelope.resize` text frame (port from `SessionClient.sendResizeToServer`)
- Modify: `Sources/GrafttyMobileKit/Remote/SSH/Channels/TerminalSessionClient.swift` — its existing `resize(cols:rows:)` method is the conformance; nothing to add
- Modify: `Sources/GrafttyMobileKit/Session/SessionClient.swift` — `sendResizeToServer` calls `try? await ws?.resize(cols:rows:)` instead of `sendText(WebControlEnvelope.resize(...))`
- Modify: `Sources/Graftty/Remote/ZmxAttachStream.swift` — implement `resize(cols:rows:)` via `TIOCSWINSZ` ioctl (port from `WebSession.resize`)

- [ ] **Step 1:** Read `Sources/GrafttyKit/Web/WebServer.swift` `WebSession.resize` (around line 1027) to see the existing TIOCSWINSZ pattern.

- [ ] **Step 2:** Add to `WebSocketClient` protocol:
```swift
public protocol WebSocketClient: AnyObject {
    func send(_ frame: WebSocketFrame) async throws
    func receive() async throws -> WebSocketFrame
    func close()
    /// Adjust the remote terminal's window size. URLSessionWebSocketClient
    /// sends a WebControlEnvelope text frame (/ws server intercepts).
    /// TerminalSessionClient issues an SSH window-change channel request.
    /// Default: no-op so non-PTY consumers don't have to implement.
    func resize(cols: Int, rows: Int) async
}

public extension WebSocketClient {
    func resize(cols: Int, rows: Int) async {}
}
```

- [ ] **Step 3:** Add `resize` to `URLSessionWebSocketClient`:
```swift
public func resize(cols: Int, rows: Int) async {
    let payload = WebControlEnvelope.resize(cols: UInt16(cols), rows: UInt16(rows)).encoded()
    try? await send(.text(payload))
}
```

- [ ] **Step 4:** `TerminalSessionClient.resize` signature: current is `async throws`. Change to `async` (non-throwing) to match the protocol. Swallow internal throw with `try?`:
```swift
public func resize(cols: Int, rows: Int) async {
    let child = lock.withLock { childChannel }
    guard let child else { return }
    let event = SSHChannelRequestEvent.WindowChangeRequest(
        terminalCharacterWidth: cols,
        terminalRowHeight: rows,
        terminalPixelWidth: 0,
        terminalPixelHeight: 0
    )
    try? await child.triggerUserOutboundEvent(event).get()
}
```

- [ ] **Step 5:** `SessionClient.sendResizeToServer` — replace `sendText(WebControlEnvelope.resize(...).encoded())` with:
```swift
private func sendResizeToServer(cols: UInt16, rows: UInt16) {
    Task { [weak self] in
        guard let self else { return }
        guard let ws = await self.awaitWS() else { return }
        await ws.resize(cols: Int(cols), rows: Int(rows))
    }
}
```

- [ ] **Step 6:** Implement `ZmxAttachStream.resize`:
```swift
func resize(cols: Int, rows: Int) async {
    var ws = winsize()
    ws.ws_col = UInt16(cols)
    ws.ws_row = UInt16(rows)
    let fd = stdinPipe.fileHandleForWriting.fileDescriptor
    _ = ioctl(fd, TIOCSWINSZ, &ws)
    // Best-effort: ignore ioctl failures (process gone, fd closed).
    // /ws's WebSession.resize takes the same posture.
}
```
Add `import Darwin` if not already present.

- [ ] **Step 7:** Build + test:
```bash
swift build 2>&1 | tail -5
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -10
```
Expected: clean build + full test suite passes.

- [ ] **Step 8:** Commit:
```
fix(R4 review): plumb iPad terminal resize through SSH path

WebSocketClient gains a resize(cols:rows:) protocol method with a
default no-op. URLSessionWebSocketClient sends the existing
WebControlEnvelope text frame (/ws server intercepts).
TerminalSessionClient issues an SSH window-change channel request.
SessionClient.sendResizeToServer calls ws.resize(...) polymorphically
instead of sending a WebControlEnvelope text frame unconditionally
(which on the SSH path became JSON garbage on zmx stdin).

ZmxAttachStream.resize now invokes TIOCSWINSZ — parity with
WebSession.resize on the /ws path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 2: ZmxAttachStream crash protection (Findings #2, #15)

**Files:** `Sources/Graftty/Remote/ZmxAttachStream.swift`

Two bugs:
- `send()` writes to the stdin pipe after `close()` terminated the process → `NSFileHandleOperationException` (ObjC, uncatchable) → Mac crash
- `readabilityHandler` already-dispatched GCD blocks fire after `close()` set the handler to nil

Fix: add a lock-protected `closed` flag; gate `send()` on it; order `close()` so the read handler nils + finish() happens before process.terminate(); for the write side, wrap the write in `ObjCExceptionCatcher` (Swift bridge) or check `process.isRunning` AND catch failures by serializing on a queue.

- [ ] **Step 1:** Add `NIOLock` state guard:
```swift
import NIOConcurrencyHelpers

final class ZmxAttachStream: TerminalByteStream, @unchecked Sendable {
    // ... existing properties ...
    private let lock = NIOLock()
    private var closed = false
```

- [ ] **Step 2:** Refactor `send()` to bail if closed and use a try-catch for write failures (won't catch NSException but catches POSIX `EPIPE` via FileHandle's modern API on macOS 13+). For pre-13 / robust handling, dispatch via a writer DispatchQueue serialized with close:
```swift
func send(_ bytes: Data) async throws {
    let proceed: Bool = lock.withLock {
        return !closed && process.isRunning
    }
    guard proceed else { return }
    // On macOS 11+ FileHandle.write(contentsOf:) throws on broken pipe
    // instead of raising NSFileHandleOperationException, IF available.
    // Test target is macOS 14 per Package.swift platforms, so safe.
    do {
        try stdinPipe.fileHandleForWriting.write(contentsOf: bytes)
    } catch {
        // Broken pipe means the zmx attach process exited; nothing
        // to do — close() will or has run.
    }
}
```

- [ ] **Step 3:** Refactor `close()` to set closed first, drain handlers safely:
```swift
func close() async {
    let shouldRunCleanup: Bool = lock.withLock {
        guard !closed else { return false }
        closed = true
        return true
    }
    guard shouldRunCleanup else { return }
    
    // Nil the read handler BEFORE finish(); any already-dispatched
    // block sees yield-after-finish as a no-op per AsyncStream docs.
    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    continuation.finish()
    if process.isRunning {
        process.terminate()
    }
}
```

- [ ] **Step 4:** Same idempotency guard for the readability handler's EOF path:
```swift
stdout.fileHandleForReading.readabilityHandler = { [continuation = self.continuation, weak self] handle in
    let data = handle.availableData
    if data.isEmpty {
        Task { await self?.close() }  // EOF: close to terminate process
    } else {
        continuation.yield(data)
    }
}
```
(The Task indirection avoids calling close() from a non-async GCD context.)

- [ ] **Step 5:** Build + test:
```bash
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
```

- [ ] **Step 6:** Commit:
```
fix(R4 review): ZmxAttachStream send/close races

- send() now bails if close() ran (lock-protected `closed` flag) and
  catches POSIX write errors (broken pipe) instead of risking an
  ObjC NSFileHandleOperationException that Swift can't catch.
- close() is idempotent (set closed flag first) and orders teardown:
  nil read handler -> finish() continuation -> terminate process.
- Read handler's EOF path now calls close() via a Task instead of
  yielding the empty data again.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 3: SSH install path race/leak fixes (Findings #3, #4, #9, #10, #13)

**Files:**
- `Sources/GrafttyHostAgent/WebRTCHostAgent.swift`
- `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift`

Five related issues — single design pattern fixes them all:

1. Add `private var sshInstallStarted = false` to both actors.
2. `installSSHHandler` / `installSSHHandlerAndResume` early-return if `sshInstallStarted == true`. Set it `= true` at the top of the method (under actor isolation, no race).
3. Wrap the SSH transport assignment so it happens BEFORE `await transport.start()`, eliminating the actor-reentrancy gap.
4. In the catch blocks of both methods, call `await transport.close()` to release the transport on failure.
5. In `installSSHHandlerAndResume`, guard on `openContinuation != nil` before mutating `state` — if the timeout has fired, openContinuation will be nil and we shouldn't overwrite `.failed`.

- [ ] **Step 1:** WebRTCHostAgent changes:
```swift
private var sshInstallStarted = false

private func installSSHHandler() async {
    guard !sshInstallStarted else { return }
    sshInstallStarted = true
    guard let dc = dataChannel else { return }
    let transport = SSHNIOTransport(dataChannel: dc)
    self.sshTransport = transport  // assign before start so close() can find it
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
        self.state = .connected
    } catch {
        await transport.close()
        self.sshTransport = nil
        self.state = .failed(reason: "SSH install failed: \(error)")
    }
}
```

- [ ] **Step 2:** RemoteHostConnection changes — same `sshInstallStarted` flag pattern, plus the timeout guard:
```swift
private var sshInstallStarted = false

private func installSSHHandlerAndResume() async {
    guard !sshInstallStarted else { return }
    sshInstallStarted = true
    guard let dc = dataChannel else { return }
    let transport = SSHNIOTransport(dataChannel: dc)
    self.sshTransport = transport  // assign before start (close() can find it)
    do {
        let box: SSHHandlerBox = try await transport.eventLoop.submit { [clientKey, expectedHostFingerprint] in
            let h = SSHClientSetup.makeHandler(
                clientKey: clientKey,
                expectedHostFingerprint: expectedHostFingerprint,
                allocator: transport.channel.allocator
            )
            try transport.channel.pipeline.syncOperations.addHandler(h)
            return SSHHandlerBox(handler: h)
        }.get()
        try await transport.start()
        self.sshHandlerBox = box
        // Guard: if openContinuation is nil, the open already timed out
        // or close() resumed it; don't overwrite .failed/.closed with .connected.
        if openContinuation != nil {
            self.state = .connected
            openContinuation?.resume(returning: ())
            openContinuation = nil
        }
    } catch {
        await transport.close()
        self.sshTransport = nil
        if openContinuation != nil {
            self.state = .failed(reason: "SSH handshake failed: \(error)")
            openContinuation?.resume(throwing: error)
            openContinuation = nil
        }
    }
}
```

- [ ] **Step 3:** Also in `RemoteHostConnection.waitForDataChannelOpen`, remove the redundant re-check inside the `withCheckedThrowingContinuation` block that spawns a second install Task. The `dataChannelDelegate.onOpen` install AND the initial guard cover all cases — the inner re-check is the source of the third install path.

- [ ] **Step 4:** Build + test (both Mac and iOS):
```bash
swift build 2>&1 | tail -5
xcodebuild ... test 2>&1 | tail -10
```

- [ ] **Step 5:** Commit:
```
fix(R4 review): SSH install path race/leak fixes

Five related bugs in WebRTCHostAgent.installSSHHandler and
RemoteHostConnection.installSSHHandlerAndResume:

1. Double-install if DataChannel is already open at adoptDataChannel /
   waitForDataChannelOpen time (early-open path + onOpen callback both
   fire). Guarded by sshInstallStarted flag, idempotent.
2. Actor reentrancy: close() between `await transport.eventLoop.submit`
   and `self.sshTransport = transport` left transport un-closed. Now
   assigns sshTransport before the await, so close() always finds it.
3. Catch block leaked transport on failure. Now calls
   `await transport.close()` + nils sshTransport.
4. Timeout race: handleDataChannelOpenTimeout sets state=.failed, but a
   late-arriving install could overwrite .connected. Guarded by checking
   openContinuation != nil before mutating state.
5. Removed redundant re-check inside RemoteHostConnection's
   withCheckedThrowingContinuation that was the source of the third
   install path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 4: TerminalSessionClient lifecycle fixes (Findings #6, #7, #8, #11)

**Files:** `Sources/GrafttyMobileKit/Remote/SSH/Channels/TerminalSessionClient.swift`

Four lifecycle bugs in `connect()` and `close()`:

- (#6) `connect()` returns before server-side `streamFactory` actually attaches; bytes sent in the gap are dropped server-side
- (#7) `close()` before `connect()` completes leaves child channel open + pendingReceivers hang
- (#8) `InboundRelay.owner` weak — bytes silently dropped + receivers leak if caller drops the client
- (#11) `connect()` doesn't close the freshly-created child channel if sendEnv/Pty/Shell throws

Combined fix:

1. **Strong InboundRelay owner.** Change `weak var owner` to `let owner` (strong). The cycle is bounded — relay lives in the SSH child channel pipeline; child channel close releases it (via NIO removing handlers from pipeline). TerminalSessionClient retains parentChannel/parentHandler/sessionName but doesn't retain the relay directly; the relay retains the client; closing the child channel drains the cycle.
2. **Defer-close in connect():** wrap sendEnv/sendPty/sendShell in a do/catch that closes `child` on any failure.
3. **Wait for shell ack.** Currently `sendShell` only awaits the NIO write future, not the server's ChannelSuccessEvent reply. Install a one-shot handler in the child pipeline (before sending shell) that captures the next inbound `ChannelSuccessEvent` / `ChannelFailureEvent` and resolves a promise. `connect()` awaits that promise after sendShell.
4. **close() drains pendingReceivers** even if childChannel is nil (call `handleChildClose()` directly).

- [ ] **Step 1:** Strong owner — change `weak var owner` to `let owner`:
```swift
private final class InboundRelay: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let owner: TerminalSessionClient  // was weak var

    init(owner: TerminalSessionClient) {
        self.owner = owner
    }
    // ... rest unchanged, owner. instead of owner?.
}
```

- [ ] **Step 2:** Add a shell-ack waiter handler installed in the child pipeline before sending shell. Document: when ChannelSuccessEvent or ChannelFailureEvent fires from the server, complete a promise; connect() awaits it.

```swift
// Add inside TerminalSessionClient.swift after InboundRelay:
private final class ShellAckWaiter: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = SSHChannelData
    let promise: EventLoopPromise<Void>

    init(promise: EventLoopPromise<Void>) { self.promise = promise }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            promise.succeed(())
            context.pipeline.removeHandler(self, promise: nil)
        case is ChannelFailureEvent:
            promise.fail(TerminalSessionClient.ClientError.openFailed(ShellRejectedError()))
            context.pipeline.removeHandler(self, promise: nil)
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }
}

private struct ShellRejectedError: Error {}
```

Update `connect()`:
```swift
public func connect() async throws {
    let promise = parentChannel.eventLoop.makePromise(of: Channel.self)
    parentHandler.createChannel(promise, channelType: .session) { [self] child, _ in
        child.pipeline.addHandler(InboundRelay(owner: self))
    }
    let child: Channel
    do {
        child = try await promise.futureResult.get()
    } catch {
        throw ClientError.openFailed(error)
    }
    
    // Install shell ack waiter BEFORE sending shell.
    let ackPromise = child.eventLoop.makePromise(of: Void.self)
    try await child.pipeline.addHandler(ShellAckWaiter(promise: ackPromise))
    
    do {
        try await Self.sendEnv(channel: child, name: "GRAFTTY_SESSION", value: sessionName)
        try await Self.sendPty(channel: child, term: "xterm-256color", cols: 80, rows: 24)
        try await Self.sendShell(channel: child)
        try await ackPromise.futureResult.get()  // <-- wait for server attach
    } catch {
        child.close(promise: nil)
        throw error
    }

    lock.withLock { childChannel = child }
    child.closeFuture.whenComplete { [weak self] _ in self?.handleChildClose() }
}
```

- [ ] **Step 3:** `close()` drains pendingReceivers even when childChannel is nil:
```swift
public func close() {
    let child: Channel? = lock.withLock { () -> Channel? in
        closed = true
        return childChannel
    }
    if let child {
        child.close(promise: nil)
    } else {
        // No child yet (close raced with connect). Drain pendingReceivers
        // ourselves so callers don't hang.
        handleChildClose()
    }
}
```

- [ ] **Step 4:** Build + test (iOS):
```bash
xcodebuild ... test 2>&1 | tail -10
```

Specifically run `SSHTerminalLoopbackTests` to confirm the shell-ack waiter doesn't break the existing positive test:
```bash
xcodebuild ... test -only-testing:GrafttyMobileKitTests/SSHTerminalLoopbackTests 2>&1 | tail -10
```

- [ ] **Step 5:** Commit:
```
fix(R4 review): TerminalSessionClient lifecycle fixes

Four lifecycle bugs:

1. connect() previously returned as soon as `shell` was written, not
   when the server actually attached the stream. Bytes sent in the
   window between connect() returning and TerminalSessionHandler.attach
   completing (10-100ms during zmx fork+exec) were dropped by the
   handler's `guard stream != nil` check. Now waits for the server's
   ChannelSuccess reply via a one-shot ShellAckWaiter handler.

2. close() before connect() completes left the child channel open
   (child?.close on nil = no-op) AND left pendingReceivers hanging.
   Now drains pendingReceivers itself if childChannel is nil.

3. InboundRelay.owner was weak — caller dropping the TerminalSessionClient
   strong reference while the channel was alive silently dropped inbound
   bytes AND leaked receivers. Made strong; the cycle is broken when
   NIO removes the handler from the closed pipeline.

4. connect() didn't close the child channel on send-env/pty/shell
   failure — orphaned SSH channel. Now wrapped in do/catch that calls
   child.close on any failure.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 5: Quick fixes bundle (Findings #5, #12, #14)

**Files:**
- `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift`
- `Sources/GrafttyMobileKit/Session/SessionClient.swift`

Three small fixes:

- (#5) Restore `RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)` in RemoteHostConnection. Mirror what WebRTCHostAgent already does.
- (#12) `SessionClient.forceReconnectNow` — close old ws + cancel wsReadyTask before start():
```swift
public func forceReconnectNow() {
    guard !stopped else { return }
    wsReadyTask?.cancel()
    wsReadyTask = nil
    ws?.close()
    ws = nil
    receiveTask?.cancel()
    receiveTask = nil
    start()
}
```
- (#14) `nonisolated(unsafe)` data race on `wsReadyTask`/`ws`: replace with NIOLock-protected access pattern.

For (#14), the cleanest minimal change without revisiting the whole SessionClient async model: add a `private let stateLock = NIOLock()` and have all reads/writes of `ws` and `wsReadyTask` go through it. This loses the `nonisolated(unsafe)` annotation. Inside `withLock`, the work is purely property assignment/read — no async, no recursion.

Sketch:
```swift
private let stateLock = NIOLock()
private var _ws: WebSocketClient?
private var _wsReadyTask: Task<WebSocketClient?, Never>?

private func currentWS() -> WebSocketClient? {
    stateLock.withLock { _ws }
}
private func currentWSReadyTask() -> Task<WebSocketClient?, Never>? {
    stateLock.withLock { _wsReadyTask }
}
private func setWS(_ value: WebSocketClient?) {
    stateLock.withLock { _ws = value }
}
private func setWSReadyTask(_ value: Task<WebSocketClient?, Never>?) {
    stateLock.withLock { _wsReadyTask = value }
}
```
Update every reader to call `currentWS()` / `currentWSReadyTask()` and every writer to call setters. The `nonisolated(unsafe)` annotations come off.

- [ ] **Step 1:** Restore nil-codec factories in RemoteHostConnection init.
- [ ] **Step 2:** Fix forceReconnectNow leak.
- [ ] **Step 3:** Replace nonisolated(unsafe) with NIOLock-protected accessors throughout SessionClient.
- [ ] **Step 4:** Build + iOS test.
- [ ] **Step 5:** Commit:
```
fix(R4 review): quick bundle — codec factory, forceReconnect, lock

- RemoteHostConnection restores RTCPeerConnectionFactory(encoderFactory:
  nil, decoderFactory: nil) — DataChannel-only path doesn't need hardware
  H.264/VP8/VP9 codec init, which the diff accidentally re-enabled.
  Matches what WebRTCHostAgent already does.
- SessionClient.forceReconnectNow now closes old ws + cancels
  wsReadyTask before start() — was leaking the previous connection.
- Replaced nonisolated(unsafe) on _ws/_wsReadyTask with NIOLock-protected
  accessors; awaitWS() and other readers go through currentWS() /
  currentWSReadyTask().

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 6: /simplify + push update

- [ ] Run `code-simplifier:code-simplifier` over the cumulative review-fix diff
- [ ] Apply any safe simplifications it finds
- [ ] Push to origin
- [ ] Confirm CI passes
