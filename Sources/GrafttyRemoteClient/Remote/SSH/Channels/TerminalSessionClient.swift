import Foundation
import GrafttyProtocol
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH

/// Client-side `WebSocketClient` conformer that carries graftty terminal
/// I/O over an SSH session child channel.
///
/// Lifecycle:
///   1. `connect()` opens an SSH child channel of type `.session` via
///      the parent `NIOSSHHandler`, sends `env GRAFTTY_SESSION=<name>`,
///      `pty-req`, `shell`. Resolves when shell is accepted.
///   2. `send(.binary(data))` writes the bytes as `SSHChannelData` to
///      the channel.
///   3. `receive()` returns the next frame from an internal buffer
///      (populated by the inbound handler): `.binary` for `.channel`
///      terminal bytes, `.text` for a decoded `.stdErr` control
///      envelope (see REMOTE-9 below).
///   4. `resize(cols:rows:)` sends an SSH `window-change` channel
///      request. Kept unconditionally (not gated on ownership) — it's
///      what makes the PTY actually resize server-side for legacy
///      (pre-`.hello`) servers, and is harmless once the control
///      carrier is active (the server owner-gates it the same way it
///      gates the web transport's legacy `resize` frame).
///   5. `close()` closes the SSH child channel; the server-side handler
///      sees `channelInactive` and tears down the stream.
///
/// REMOTE-9 / `supportsWebControlTextFrames = true`: display ownership
/// (`hello`/`takeControl`/`ownerResize`) rides the SAME session channel
/// as terminal bytes, multiplexed by `SSHChannelData.type` exactly like
/// `GrafttyHostAgent`'s `TerminalSessionHandler` — `.channel` carries
/// raw PTY bytes (unchanged), `.stdErr` carries length-prefixed
/// (`<u32 BE length><UTF-8 JSON>`) `WebControlEnvelope` frames in both
/// directions. `sendHello`/`takeControl`/`ownerResize` encode+frame+write
/// a `.stdErr` frame; `InboundRelay` deframes inbound `.stdErr` bytes and
/// surfaces each complete envelope's JSON as `WebSocketFrame.text(_:)`,
/// which `SessionClient.handleTextFrame` consumes unmodified — the same
/// contract `URLSessionWebSocketClient` provides over `/ws`.
public final class TerminalSessionClient: WebSocketClient, @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case notConnected
        case channelClosed
        /// The remote PTY process reached EOF and deliberately closed the
        /// SSH child channel. This is not a retryable transport failure.
        case sessionEnded(exitStatus: Int)
        case openFailed(any Error)
    }

    private let parentChannel: Channel
    private let parentHandler: NIOSSHHandler
    private let sessionName: String
    private let lock = NIOLock()
    private var childChannel: Channel?
    private var receiveBuffer: [WebSocketFrame] = []
    private var pendingReceivers: [CheckedContinuation<WebSocketFrame, Error>] = []
    private var didFailReceive: (any Error)?
    private var closed = false

    public var supportsWebControlTextFrames: Bool { true }

    public init(parentChannel: Channel, parentHandler: NIOSSHHandler, sessionName: String) {
        self.parentChannel = parentChannel
        self.parentHandler = parentHandler
        self.sessionName = sessionName
    }

    /// Opens the SSH session child channel and completes env+pty+shell.
    /// Resolves only after the server acknowledges the shell request
    /// (ChannelSuccessEvent), ensuring the server-side stream is attached
    /// before the caller sends any terminal bytes.
    public func connect() async throws {
        let child: Channel
        do {
            child = try await openChildChannel(
                parentChannel: parentChannel,
                parentHandler: parentHandler
            ) { [self] child, _ in
                child.pipeline.addHandler(InboundRelay(owner: self))
            }
        } catch {
            throw ClientError.openFailed(error)
        }

        // env and pty don't need replies — server always accepts them and
        // we don't need to sequence on their ChannelSuccessEvents.
        // Only the shell reply is meaningful: it arrives after the async
        // streamFactory(name) completes on the server side.
        do {
            try await Self.sendEnv(channel: child, name: "GRAFTTY_SESSION", value: sessionName)
            try await Self.sendPty(channel: child, term: "xterm-256color", cols: 80, rows: 24)
        } catch {
            child.close(promise: nil)
            throw error
        }

        // Install the shell-ack waiter BEFORE sending shell so we don't
        // miss the server's ChannelSuccessEvent reply. Env/pty replies
        // have already been flushed above; the pipeline only sees the
        // shell reply from this point on.
        let ackPromise = child.eventLoop.makePromise(of: Void.self)
        try await child.pipeline.addHandler(ShellAckWaiter(promise: ackPromise))

        do {
            try await Self.sendShell(channel: child)
            // Wait for the server's attach to complete — TerminalSessionHandler
            // fires ChannelSuccessEvent only after streamFactory(name) resolves.
            try await ackPromise.futureResult.get()
        } catch {
            // Close the orphaned child channel and re-throw.
            child.close(promise: nil)
            throw error
        }

        lock.withLock { childChannel = child }

        // Watch for child-channel close so receivers waiting in
        // `receive()` see channelClosed instead of hanging.
        child.closeFuture.whenComplete { [weak self] _ in
            self?.handleChildClose()
        }
    }

    public func send(_ frame: WebSocketFrame) async throws {
        switch frame {
        case .binary(let data):
            let child = lock.withLock { childChannel }
            guard let child else { throw ClientError.notConnected }
            let buffer = child.allocator.buffer(bytes: data)
            let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            try await child.writeAndFlush(channelData).get()
        case .text(let payload):
            // Route through the same `.stdErr` control carrier `receive()`
            // surfaces `.text` from — `URLSessionWebSocketClient` treats
            // `.text` as its native control encoding, so any polymorphic
            // caller sending `.text` through this client must land on the
            // control carrier too, not as `.channel` PTY bytes (which
            // would corrupt terminal output on the wire).
            try await sendRawControlFrame(payload)
        }
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
                    cont.resume(returning: next)
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
        let child: Channel? = lock.withLock {
            closed = true
            return childChannel
        }
        if let child {
            child.close(promise: nil)
        } else {
            // No child yet — close() raced connect() before childChannel
            // was assigned. Drain pendingReceivers so callers don't hang.
            handleChildClose()
        }
    }

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

    // MARK: - REMOTE-9 control-envelope senders

    public func sendHello(
        clientID: DisplayClientID,
        kind: DisplayClientKind,
        role: DisplayClientRole,
        visible: Bool,
        cols: Int,
        rows: Int
    ) async {
        await sendControlEnvelope(.hello(
            clientID: clientID,
            kind: kind,
            role: role,
            visible: visible,
            cols: Self.gridDimension(cols),
            rows: Self.gridDimension(rows)
        ))
    }

    public func takeControl(clientID: DisplayClientID, kind: DisplayClientKind, cols: Int, rows: Int) async {
        await sendControlEnvelope(.takeControl(
            clientID: clientID,
            kind: kind,
            cols: Self.gridDimension(cols),
            rows: Self.gridDimension(rows)
        ))
    }

    public func ownerResize(clientID: DisplayClientID, epoch: UInt64, cols: Int, rows: Int) async {
        await sendControlEnvelope(.ownerResize(
            clientID: clientID,
            epoch: epoch,
            cols: Self.gridDimension(cols),
            rows: Self.gridDimension(rows)
        ))
    }

    /// Every current caller (`SessionClient`) derives cols/rows from
    /// `UInt16`-typed grids, so this is a no-op today — but these are
    /// public `Int`-taking API and a trapping `UInt16(_:)` conversion
    /// would crash the app on a transient out-of-range layout value.
    /// Clamp into the valid grid range instead (floor 1 keeps the
    /// envelope parseable), AND cap at `WebControlEnvelope.maxGridDimension`
    /// — the same shared bound the server's parser and pty-req/window-change
    /// clamping use (`WebControlEnvelope.clampedGridDimension`). Without the
    /// upper cap here, a transient out-of-range layout value could still be
    /// encoded into a hello/takeControl/ownerResize envelope that the
    /// server-side parser rejects — pre-lenient-hello, that could
    /// permanently strand the connection; even with the server's lenient
    /// fallback, sending an envelope this client itself would reject on
    /// the way in is never correct.
    private static func gridDimension(_ value: Int) -> UInt16 {
        WebControlEnvelope.clampedGridDimension(max(1, value))
    }

    /// Fire-and-forget wrapper around `sendRawControlFrame` for the
    /// internal REMOTE-9 senders (hello/takeControl/ownerResize). Silent
    /// no-op if the channel isn't open yet or the write fails; callers
    /// (`SessionClient`) treat these as fire-and-forget, exactly like
    /// `URLSessionWebSocketClient`'s `try? await send(.text(...))`.
    private func sendControlEnvelope(_ envelope: WebControlEnvelope) async {
        try? await sendRawControlFrame(envelope.encoded())
    }

    /// Length-prefixes `payload` (`<u32 BE length><UTF-8 JSON>`) and writes
    /// it as a `.stdErr`-typed `SSHChannelData` on the session channel — the
    /// same wire shape `StdErrControlFraming.encode` produces server-side
    /// via `TerminalSessionHandler`. Shared by `sendControlEnvelope` (the
    /// fire-and-forget internal senders) and `send(.text)` (the
    /// `WebSocketClient` conformance surface) so both routes land on the
    /// SAME `.stdErr` control carrier `receive()` reads back from, rather
    /// than `send(.text)` writing `.channel` PTY bytes as it did before —
    /// asymmetric with `receive()` and with `URLSessionWebSocketClient`,
    /// where `.text` IS the control encoding.
    private func sendRawControlFrame(_ payload: String) async throws {
        let child = lock.withLock { childChannel }
        guard let child else { throw ClientError.notConnected }
        guard let framed = StdErrControlFraming.encode(payload) else { return }
        var buffer = child.allocator.buffer(capacity: framed.count)
        buffer.writeBytes(framed)
        let data = SSHChannelData(type: .stdErr, data: .byteBuffer(buffer))
        try await child.writeAndFlush(data).get()
    }

    // MARK: - Inbound bytes from the SSH channel

    fileprivate func deliverInboundBinary(_ data: Data) {
        deliverInbound(.binary(data))
    }

    fileprivate func deliverInboundText(_ text: String) {
        deliverInbound(.text(text))
    }

    private func deliverInbound(_ frame: WebSocketFrame) {
        lock.withLock {
            if let next = pendingReceivers.first {
                pendingReceivers.removeFirst()
                next.resume(returning: frame)
            } else {
                receiveBuffer.append(frame)
            }
        }
    }

    fileprivate func handleChildClose() {
        let result: (
            [CheckedContinuation<WebSocketFrame, Error>],
            any Error
        ) = lock.withLock {
            let pending = pendingReceivers
            pendingReceivers.removeAll()
            closed = true
            let failure = didFailReceive ?? ClientError.channelClosed
            didFailReceive = failure
            return (pending, failure)
        }
        for cont in result.0 {
            cont.resume(throwing: result.1)
        }
    }

    fileprivate func handleSessionEnded(exitStatus: Int) {
        let failure = ClientError.sessionEnded(exitStatus: exitStatus)
        let toResume: [CheckedContinuation<WebSocketFrame, Error>] = lock.withLock {
            // Preserve the first terminal outcome if duplicate exit-status
            // events arrive. `handleChildClose` also preserves this error.
            guard didFailReceive == nil else { return [] }
            didFailReceive = failure
            closed = true
            let pending = pendingReceivers
            pendingReceivers.removeAll()
            return pending
        }
        for cont in toResume {
            cont.resume(throwing: failure)
        }
    }

    // MARK: - Channel-request senders

    private static func sendEnv(channel: Channel, name: String, value: String) async throws {
        // wantReply: false — env is always accepted by the server and
        // we don't need to sequence on the ChannelSuccessEvent reply.
        // Keeping it false avoids the ShellAckWaiter intercepting env/pty
        // replies before the shell reply it's actually waiting for.
        let event = SSHChannelRequestEvent.EnvironmentRequest(
            wantReply: false,
            name: name,
            value: value
        )
        try await channel.triggerUserOutboundEvent(event).get()
    }

    private static func sendPty(channel: Channel, term: String, cols: Int, rows: Int) async throws {
        // wantReply: false — see sendEnv comment above.
        let event = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: term,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
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
/// `SSHChannelData` to the owning `TerminalSessionClient`, demultiplexed
/// by `SSHChannelData.type` exactly like `TerminalSessionHandler` does
/// server-side: `.channel` is raw terminal bytes (unchanged), `.stdErr`
/// is the REMOTE-9 control carrier and is deframed here before being
/// surfaced as a `.text` frame.
///
/// Holds a **strong** reference to `owner`. The retain cycle
/// (TerminalSessionClient → child pipeline → InboundRelay → owner) is
/// bounded: NIO removes all handlers from the pipeline when the child
/// channel closes, breaking the cycle at that point. Using a weak ref
/// here would silently drop bytes if the caller releases its strong
/// reference to TerminalSessionClient while the channel is still alive.
///
/// `InboundRelay` runs exclusively on the child channel's event loop
/// (NIO's single-threaded-per-channel guarantee), so `stdErrDecoder`
/// / `stdErrPoisoned` need no lock — unlike
/// `TerminalSessionHandler.helloLock`, which exists there because that
/// state is also read from a different SSH connection's broadcaster
/// fan-out thread. Nothing analogous touches this client's accumulator
/// off-loop.
private final class InboundRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    let owner: TerminalSessionClient
    /// Accumulates/drains the `.stdErr` control carrier's
    /// `<u32 BE length><UTF-8 JSON>` frames — see
    /// `StdErrControlFraming` for the wire format and cap this shares
    /// with `TerminalSessionHandler` on the server side.
    private var stdErrDecoder = StdErrControlFraming.Decoder()
    /// Set once a `.stdErr` frame header claims a length above
    /// `StdErrControlFraming.maxFrameLength`, or undrained accumulation
    /// exceeds that same bound with no complete frame in sight. Framing
    /// is unrecoverable at that point (we can't tell where the next frame
    /// starts) — a single malformed frame's bytes failing UTF-8 decoding
    /// is handled separately and does NOT poison the carrier (framing
    /// stays intact; see `ingestControlBytes`). Mirrors the server
    /// (`TerminalSessionHandler.poisonStdErr`): a poisoned-but-alive
    /// client would be a frozen-ownership black hole — no more
    /// take-control/ownerResize requests could ever be parsed, and (if
    /// this client isn't the owner) inbound ownership updates would stop
    /// too — so closing the child channel here routes into
    /// `SessionClient`'s existing reconnect/backoff and self-heals
    /// instead of hanging silently forever.
    private var stdErrPoisoned = false

    init(owner: TerminalSessionClient) {
        self.owner = owner
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case let .byteBuffer(buf) = channelData.data else { return }
        var view = buf
        guard let bytes = view.readBytes(length: view.readableBytes) else { return }
        switch channelData.type {
        case .stdErr:
            ingestControlBytes(Data(bytes), context: context)
        default:
            owner.deliverInboundBinary(Data(bytes))
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            owner.handleSessionEnded(exitStatus: exit.exitStatus)
        }
        context.fireUserInboundEventTriggered(event)
    }

    /// Accumulates inbound `.stdErr` bytes and drains every complete
    /// `<u32 BE length><UTF-8 JSON>` frame via the shared
    /// `StdErrControlFraming.Decoder`, mirroring
    /// `TerminalSessionHandler.ingestStdErr`/`drainControlFrames`. A frame
    /// whose bytes aren't valid UTF-8 is dropped individually (framing is
    /// still intact — we know exactly where the next frame starts) rather
    /// than poisoning the whole carrier; only a length-prefix overflow
    /// (unrecoverable framing) poisons it.
    private func ingestControlBytes(_ data: Data, context: ChannelHandlerContext) {
        guard !stdErrPoisoned else { return }
        stdErrDecoder.append(data)
        let (frames, oversized) = stdErrDecoder.drain()
        for payload in frames {
            guard let text = String(data: payload, encoding: .utf8) else { continue }
            owner.deliverInboundText(text)
        }
        if oversized {
            poisonAndClose(context: context)
            return
        }
        // Bound undrained accumulation the same way the server does:
        // more than one max-size frame's worth of bytes past the cursor
        // with no complete frame in sight is itself a protocol violation.
        if stdErrDecoder.isOverAccumulated {
            poisonAndClose(context: context)
        }
    }

    /// Marks the carrier unrecoverably framed and closes the child
    /// channel. `channelInactive` (via `TerminalSessionClient`'s
    /// `closeFuture` observer / `handleChildClose`) then fails any
    /// pending/future `receive()` calls with `.channelClosed`, which
    /// `SessionClient` treats like any other transport drop — it
    /// reconnects with backoff rather than being stuck forever behind a
    /// carrier that can never surface another control envelope.
    private func poisonAndClose(context: ChannelHandlerContext) {
        stdErrPoisoned = true
        stdErrDecoder.reset()
        context.close(promise: nil)
    }
}

/// One-shot handler installed in the child pipeline immediately before
/// `sendShell`. Waits for the server's `ChannelSuccessEvent` (shell
/// accepted, `streamFactory` resolved) or `ChannelFailureEvent` (session
/// name missing / factory threw) and resolves `promise` accordingly.
/// Removes itself from the pipeline after the first reply so it doesn't
/// interfere with normal inbound data.
private final class ShellAckWaiter: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    let promise: EventLoopPromise<Void>

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            promise.succeed()
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
