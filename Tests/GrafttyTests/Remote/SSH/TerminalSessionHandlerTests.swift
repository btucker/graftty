import Foundation
import GrafttyHostAgent
import GrafttyKit
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

/// `TerminalSessionHandler` spawns Swift-concurrency `Task`s (to await the
/// injected `streamFactory`, forward inbound bytes, resize, and close the
/// stream) and marshals their results back onto the channel via
/// `loop.execute`. `EmbeddedChannel`/`EmbeddedEventLoop` are single-thread-only,
/// so polling `embeddedEventLoop.run()` from the test thread while those
/// background `Task`s call `loop.execute` is a data race (NIO logs
/// "EmbeddedEventLoop is not thread-safe" and the process intermittently
/// crashes). These tests use `NIOAsyncTestingChannel`, whose loop *is*
/// thread-safe: `waitForOutboundWrite` drives the loop until a deferred write
/// lands, and the side-effect assertions poll thread-safe fakes — no busy-poll
/// of the embedded loop, no race.
final class TerminalSessionHandlerTests: XCTestCase {

    // MARK: - env + pty + shell -> attach

    func testShellCallsStreamFactoryWithEnvSessionName() async throws {
        let factory = RecordingStreamFactory(returning: .success(EchoStream()))
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        let channel = try await Self.channel(handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm-256color", cols: 80, rows: 24)
        try await sendShellRequest(channel)

        // Let the Task spawned by attach() run and call the factory.
        try await waitUntil { factory.received.count > 0 }

        XCTAssertEqual(factory.received, ["alpha"])
        _ = try? await channel.finish()
    }

    func testShellWithoutEnvSessionNameRejected() async throws {
        let factory = RecordingStreamFactory(returning: .success(EchoStream()))
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        let channel = try await Self.channel(handler)

        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        // The handler closes the channel synchronously (no async involved).
        await channel.testingEventLoop.run()

        XCTAssertTrue(factory.received.isEmpty)
        XCTAssertFalse(channel.isActive)
    }

    // MARK: - bytes round-trip

    func testBytesRoundTripThroughStream() async throws {
        let stream = EchoStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let capture = OutboundEventCapture()
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        // Wait until attach installs the stream. env + pty acks fire before
        // attach; the shell ack (3rd success) fires from the same loop.execute
        // that sets `stream`, so `successCount >= 3` means the stream is
        // installed and inbound bytes won't be dropped by `guard stream != nil`.
        try await waitUntil { capture.successCount >= 3 }

        let bytes = ByteBuffer(string: "hello\n")
        try await channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(bytes)))

        // EchoStream.send() yields the bytes back via inboundBytes;
        // startInboundForwarding's Task calls loop.execute to writeAndFlush.
        // waitForOutboundWrite drives the loop until that write lands.
        let outbound = try await channel.waitForOutboundWrite(as: SSHChannelData.self)
        var echoed: String?
        if case let .byteBuffer(buf) = outbound.data {
            echoed = buf.getString(at: 0, length: buf.readableBytes)
        }

        XCTAssertEqual(echoed, "hello\n")
        _ = try? await channel.finish()
    }

    // MARK: - window-change

    func testWindowChangeForwardsToStream() async throws {
        let stream = RecordingResizeStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let capture = OutboundEventCapture()
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        // Wait until attach installs the stream (shell ack = 3rd success) so
        // window-change is forwarded rather than dropped pre-attach.
        try await waitUntil { capture.successCount >= 3 }

        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: 120,
            terminalRowHeight: 40,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        try await fireUserInboundEvent(channel, event)

        // resize is called from a Task; poll until it completes.
        try await waitUntil { stream.lastResize != nil }

        XCTAssertEqual(stream.lastResize?.cols, 120)
        XCTAssertEqual(stream.lastResize?.rows, 40)
        _ = try? await channel.finish()
    }

    // MARK: - close

    func testChannelCloseClosesStream() async throws {
        let stream = ClosableStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let capture = OutboundEventCapture()
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        // Wait until attach installs the stream (shell ack = 3rd success) so
        // channelInactive has a stream to close.
        try await waitUntil { capture.successCount >= 3 }

        _ = try? await channel.finish()
        // close() is called from a Task in channelInactive; poll until done.
        try await waitUntil { stream.didClose }

        XCTAssertTrue(stream.didClose)
    }

    // MARK: - channelInactive race with factory

    /// Channel that closes while streamFactory is awaiting must not leak
    /// the freshly-obtained stream — channelInactive racing the factory
    /// completion previously left stream un-closed.
    func testChannelInactiveDuringFactoryAwaitClosesStream() async throws {
        let stream = ClosableStream()
        // Slow factory so we can fire channelInactive before it returns.
        let delayedFactory: @Sendable (String) async throws -> any TerminalByteStream = { _ in
            try await Task.sleep(for: .milliseconds(100))
            return stream
        }
        let handler = TerminalSessionHandler(streamFactory: delayedFactory)
        let channel = try await Self.channel(handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        // Fire channelInactive while the factory is still sleeping.
        _ = try? await channel.finish()

        // Poll until the factory completes, loop.execute fires, and stream.close() is called.
        try await waitUntil(timeout: 3.0) { stream.didClose }

        XCTAssertTrue(stream.didClose, "stream from factory must be closed when channel is already inactive")
    }

    // MARK: - streamFactory throws

    func testStreamFactoryThrowsSendsExitStatusAndCloses() async throws {
        let factory = RecordingStreamFactory(returning: .failure(FactoryError.notFound))
        // Install a capture handler head-ward of TerminalSessionHandler so it
        // can record user outbound events (triggerUserOutboundEvent goes
        // head-ward through the pipeline).
        let capture = OutboundEventCapture()
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "missing")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)

        // The factory throws, then loop.execute fires exit-status + close.
        try await waitUntil { capture.sawExitStatus1 }

        XCTAssertTrue(capture.sawExitStatus1, "expected exit-status: 1 after factory throw")
    }

    // MARK: - helpers

    /// A `NIOAsyncTestingChannel` with `handlers` installed (in order, head-ward
    /// first) on its thread-safe loop, then connected so it is active — the safe
    /// substitute for `EmbeddedChannel` when the handler bounces through Swift
    /// concurrency. Connecting makes the channel active so `channelInactive`
    /// fires on close.
    private static func channel(_ handlers: NIOCore.ChannelHandler...) async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel()
        for handler in handlers {
            try await channel.pipeline.addHandler(handler).get()
        }
        try await channel.connect(to: SocketAddress(unixDomainSocketPath: "graftty-test")).get()
        return channel
    }

    private func sendEnvRequest(_ channel: NIOAsyncTestingChannel, name: String, value: String) async throws {
        let event = SSHChannelRequestEvent.EnvironmentRequest(
            wantReply: true,
            name: name,
            value: value
        )
        try await fireUserInboundEvent(channel, event)
    }

    private func sendPtyRequest(_ channel: NIOAsyncTestingChannel, term: String, cols: Int, rows: Int) async throws {
        let event = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        try await fireUserInboundEvent(channel, event)
    }

    private func sendShellRequest(_ channel: NIOAsyncTestingChannel) async throws {
        let event = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        try await fireUserInboundEvent(channel, event)
    }

    /// Fires a user inbound event through the pipeline on the channel's loop.
    /// (`NIOAsyncTestingChannel` requires pipeline operations to run on the
    /// event loop; `executeInContext` provides that.)
    private func fireUserInboundEvent(_ channel: NIOAsyncTestingChannel, _ event: some Sendable) async throws {
        try await channel.testingEventLoop.executeInContext {
            channel.pipeline.fireUserInboundEventTriggered(event)
        }
    }

    /// Polls `condition` until it returns true or the deadline is reached,
    /// suspending briefly between checks so the background `Task`s spawned by
    /// the handler (and their `loop.execute` callbacks, which self-run on the
    /// thread-safe testing loop) can make progress. Unlike the old embedded-loop
    /// busy-poll, this never touches the loop from off-thread, so there is no
    /// data race.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            // Fail fast on timeout rather than returning silently — otherwise a
            // missed barrier falls through to `waitForOutboundWrite`, which has
            // no internal timeout and would hang the whole run.
            if Date() >= deadline {
                throw WaitTimedOut()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private struct WaitTimedOut: Error, CustomStringConvertible {
    var description: String { "waitUntil timed out" }
}

// MARK: - Outbound event capture handler

/// Installed head-ward of `TerminalSessionHandler` to intercept
/// user outbound events (which `triggerUserOutboundEvent` propagates
/// toward the head of the pipeline).
private final class OutboundEventCapture: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    private let lock = NIOLock()
    private var _sawExitStatus1 = false
    private var _successCount = 0

    var sawExitStatus1: Bool {
        lock.withLock { _sawExitStatus1 }
    }

    /// Count of `ChannelSuccessEvent`s the handler has emitted. The env-req and
    /// pty-req acks fire *synchronously* (before attach), while the shell-req
    /// ack fires from the same `loop.execute` block that installs the stream —
    /// so it is the LAST of the three and reaching that count is the reliable
    /// "attach complete" signal. A prior `sawSuccess` bool tripped on the env
    /// ack, letting bytes/window-change race ahead of stream install (dropped
    /// by the handler's `guard stream != nil`).
    var successCount: Int {
        lock.withLock { _successCount }
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        if let exitStatus = event as? SSHChannelRequestEvent.ExitStatus, exitStatus.exitStatus == 1 {
            lock.withLock { _sawExitStatus1 = true }
        }
        if event is ChannelSuccessEvent {
            lock.withLock { _successCount += 1 }
        }
        context.triggerUserOutboundEvent(event, promise: promise)
    }
}

// MARK: - Test fakes

private enum FactoryError: Error { case notFound }

private final class RecordingStreamFactory: @unchecked Sendable {
    private let lock = NIOLock()
    private var _received: [String] = []
    private let result: Result<any TerminalByteStream, Error>

    var received: [String] { lock.withLock { _received } }

    init(returning result: Result<any TerminalByteStream, Error>) {
        self.result = result
    }

    var callable: @Sendable (String) async throws -> any TerminalByteStream {
        return { [self] name in
            self.lock.withLock { self._received.append(name) }
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
    private let lock = NIOLock()
    private var _lastResize: (cols: Int, rows: Int)?

    var lastResize: (cols: Int, rows: Int)? { lock.withLock { _lastResize } }

    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func send(_ bytes: Data) async throws {}
    func close() async { continuation.finish() }

    func resize(cols: Int, rows: Int) async {
        lock.withLock { _lastResize = (cols, rows) }
    }
}

/// Records close calls.
private final class ClosableStream: TerminalByteStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>
    private let lock = NIOLock()
    private var _didClose = false

    var didClose: Bool { lock.withLock { _didClose } }

    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func send(_ bytes: Data) async throws {}

    func close() async {
        lock.withLock { _didClose = true }
        continuation.finish()
    }
}
