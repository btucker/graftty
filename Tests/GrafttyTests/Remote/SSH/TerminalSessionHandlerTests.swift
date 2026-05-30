import GrafttyHostAgent
import GrafttyKit
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

final class TerminalSessionHandlerTests: XCTestCase {

    // MARK: - env + pty + shell -> attach

    func testShellCallsStreamFactoryWithEnvSessionName() throws {
        let factory = RecordingStreamFactory(returning: .success(EchoStream()))
        let channel = EmbeddedChannel()
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        try channel.pipeline.syncOperations.addHandler(handler)

        sendEnvRequest(channel: channel, name: "GRAFTTY_SESSION", value: "alpha")
        sendPtyRequest(channel: channel, term: "xterm-256color", cols: 80, rows: 24)
        sendShellRequest(channel: channel)

        // Drain: let the Task spawned by attach() run and call loop.execute.
        drainAsync(channel: channel, until: { factory.received.count > 0 })

        XCTAssertEqual(factory.received, ["alpha"])
        _ = try? channel.finish()
    }

    func testShellWithoutEnvSessionNameRejected() throws {
        let factory = RecordingStreamFactory(returning: .success(EchoStream()))
        let channel = EmbeddedChannel()
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        try channel.pipeline.syncOperations.addHandler(handler)

        sendPtyRequest(channel: channel, term: "xterm", cols: 80, rows: 24)
        sendShellRequest(channel: channel)
        channel.embeddedEventLoop.run()

        XCTAssertTrue(factory.received.isEmpty)
        // Handler closed the channel synchronously (no async involved for this case).
        XCTAssertFalse(channel.isActive)
    }

    // MARK: - bytes round-trip

    func testBytesRoundTripThroughStream() throws {
        let stream = EchoStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let channel = EmbeddedChannel()
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        try channel.pipeline.syncOperations.addHandler(handler)

        sendEnvRequest(channel: channel, name: "GRAFTTY_SESSION", value: "alpha")
        sendPtyRequest(channel: channel, term: "xterm", cols: 80, rows: 24)
        sendShellRequest(channel: channel)
        // Drain until attach completes and stream is installed.
        drainAsync(channel: channel, until: { factory.received.count > 0 })

        let bytes = ByteBuffer(string: "hello\n")
        try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(bytes)))

        // EchoStream.send() yields the bytes back via inboundBytes;
        // startInboundForwarding's Task calls loop.execute to writeAndFlush.
        var echoed: String?
        drainAsync(channel: channel, until: {
            if let outbound: SSHChannelData = try? channel.readOutbound() {
                if case let .byteBuffer(buf) = outbound.data {
                    echoed = buf.getString(at: 0, length: buf.readableBytes)
                }
            }
            return echoed != nil
        })

        XCTAssertEqual(echoed, "hello\n")
        _ = try? channel.finish()
    }

    // MARK: - window-change

    func testWindowChangeForwardsToStream() throws {
        let stream = RecordingResizeStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let channel = EmbeddedChannel()
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        try channel.pipeline.syncOperations.addHandler(handler)

        sendEnvRequest(channel: channel, name: "GRAFTTY_SESSION", value: "alpha")
        sendPtyRequest(channel: channel, term: "xterm", cols: 80, rows: 24)
        sendShellRequest(channel: channel)
        // Drain until attach completes and stream is installed.
        drainAsync(channel: channel, until: { factory.received.count > 0 })

        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: 120,
            terminalRowHeight: 40,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        channel.pipeline.fireUserInboundEventTriggered(event)

        // resize is called from a Task; drain until it completes.
        drainAsync(channel: channel, until: { stream.lastResize != nil })

        XCTAssertEqual(stream.lastResize?.cols, 120)
        XCTAssertEqual(stream.lastResize?.rows, 40)
        _ = try? channel.finish()
    }

    // MARK: - close

    func testChannelCloseClosesStream() throws {
        let stream = ClosableStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let channel = EmbeddedChannel()
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        try channel.pipeline.syncOperations.addHandler(handler)

        sendEnvRequest(channel: channel, name: "GRAFTTY_SESSION", value: "alpha")
        sendPtyRequest(channel: channel, term: "xterm", cols: 80, rows: 24)
        sendShellRequest(channel: channel)
        // Drain until attach completes and stream is installed.
        drainAsync(channel: channel, until: { factory.received.count > 0 })

        _ = try? channel.finish()
        // close() is called from a Task in channelInactive; drain until done.
        drainAsync(channel: channel, until: { stream.didClose })

        XCTAssertTrue(stream.didClose)
    }

    // MARK: - channelInactive race with factory

    /// Channel that closes while streamFactory is awaiting must not leak
    /// the freshly-obtained stream — channelInactive racing the factory
    /// completion previously left stream un-closed.
    func testChannelInactiveDuringFactoryAwaitClosesStream() throws {
        let stream = ClosableStream()
        // Slow factory so we can fire channelInactive before it returns.
        let delayedFactory: @Sendable (String) async throws -> any TerminalByteStream = { _ in
            try await Task.sleep(for: .milliseconds(100))
            return stream
        }
        let channel = EmbeddedChannel()
        let handler = TerminalSessionHandler(streamFactory: delayedFactory)
        try channel.pipeline.syncOperations.addHandler(handler)

        sendEnvRequest(channel: channel, name: "GRAFTTY_SESSION", value: "alpha")
        sendPtyRequest(channel: channel, term: "xterm", cols: 80, rows: 24)
        sendShellRequest(channel: channel)
        // Fire channelInactive while the factory is still sleeping.
        _ = try? channel.finish()

        // Drain until the factory completes, loop.execute fires, and stream.close() is called.
        drainAsync(channel: channel, until: { stream.didClose }, timeout: 3.0)

        XCTAssertTrue(stream.didClose, "stream from factory must be closed when channel is already inactive")
    }

    // MARK: - streamFactory throws

    func testStreamFactoryThrowsSendsExitStatusAndCloses() throws {
        let factory = RecordingStreamFactory(returning: .failure(FactoryError.notFound))
        let channel = EmbeddedChannel()
        // Install a capture handler head-ward of TerminalSessionHandler so it
        // can record user outbound events (triggerUserOutboundEvent goes
        // head-ward through the pipeline).
        let capture = OutboundEventCapture()
        try channel.pipeline.syncOperations.addHandler(capture)
        let handler = TerminalSessionHandler(streamFactory: factory.callable)
        try channel.pipeline.syncOperations.addHandler(handler)

        sendEnvRequest(channel: channel, name: "GRAFTTY_SESSION", value: "missing")
        sendPtyRequest(channel: channel, term: "xterm", cols: 80, rows: 24)
        sendShellRequest(channel: channel)

        // The factory throws, then loop.execute fires exit-status + close.
        drainAsync(channel: channel, until: { capture.sawExitStatus1 })

        XCTAssertTrue(capture.sawExitStatus1, "expected exit-status: 1 after factory throw")
    }

    // MARK: - helpers

    private func sendEnvRequest(channel: EmbeddedChannel, name: String, value: String) {
        let event = SSHChannelRequestEvent.EnvironmentRequest(
            wantReply: true,
            name: name,
            value: value
        )
        channel.pipeline.fireUserInboundEventTriggered(event)
    }

    private func sendPtyRequest(channel: EmbeddedChannel, term: String, cols: Int, rows: Int) {
        let event = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        channel.pipeline.fireUserInboundEventTriggered(event)
    }

    private func sendShellRequest(channel: EmbeddedChannel) {
        let event = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        channel.pipeline.fireUserInboundEventTriggered(event)
    }

    /// Spins the main RunLoop in short bursts while calling
    /// `embeddedEventLoop.run()` after each burst, until `condition()`
    /// returns true or the deadline is reached. The short RunLoop burst
    /// lets Swift concurrency tasks (spawned by the handler) make
    /// progress; the `embeddedEventLoop.run()` call delivers any work
    /// those tasks scheduled back onto the embedded loop.
    private func drainAsync(
        channel: EmbeddedChannel,
        until condition: () -> Bool,
        timeout: TimeInterval = 2.0
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            channel.embeddedEventLoop.run()
        }
    }
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

    var sawExitStatus1: Bool {
        lock.withLock { _sawExitStatus1 }
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        if let exitStatus = event as? SSHChannelRequestEvent.ExitStatus, exitStatus.exitStatus == 1 {
            lock.withLock { _sawExitStatus1 = true }
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
