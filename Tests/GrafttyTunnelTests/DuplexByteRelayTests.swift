import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import GrafttyTunnel

@Suite("@spec REMOTE-26.27: When relaying replication bytes, the application shall drain writes before forwarding input EOF, preserve the reverse stream, and close both endpoints on cancellation, deadline, failed authorization, or oversized input.")
struct DuplexByteRelayTests {
    @Test(.timeLimit(.minutes(1)))
    func halfCloseWaitsForWriteAndPreservesReverseStream() async throws {
        let left = try await endpoint()
        let right = try await endpoint(delayWrites: true)
        let task = Task {
            try await DuplexByteRelay.run(left.stream, right.stream, deadline: .now.advanced(by: .seconds(5)), authorize: {})
        }
        _ = try await left.channel.writeInbound(ByteBuffer(string: "pack bytes"))
        try await right.handler.writeStarted.futureResult.get()
        try await left.channel.eventLoop.submit {
            left.channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        }.get()
        #expect(try await right.channel.eventLoop.submit { right.handler.halfClosed == false }.get())
        try await right.channel.eventLoop.submit { right.handler.completeWrite() }.get()
        let sent = try await right.channel.waitForOutboundWrite(as: ByteBuffer.self)
        #expect(String(buffer: sent) == "pack bytes")
        try await right.handler.outputClosed.futureResult.get()
        _ = try await right.channel.writeInbound(ByteBuffer(string: "receiver result"))
        let reply = try await left.channel.waitForOutboundWrite(as: ByteBuffer.self)
        #expect(String(buffer: reply) == "receiver result")
        try await right.channel.eventLoop.submit {
            right.channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        }.get()
        try await task.value
        #expect(!left.channel.isActive)
        #expect(!right.channel.isActive)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationClosesStalledWriteAndIdleReverseRead() async throws {
        let left = try await endpoint()
        let right = try await endpoint(delayWrites: true)
        let task = Task {
            try await DuplexByteRelay.run(left.stream, right.stream, deadline: .now.advanced(by: .seconds(5)), authorize: {})
        }
        _ = try await left.channel.writeInbound(ByteBuffer(string: "pending"))
        try await right.handler.writeStarted.futureResult.get()
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!left.channel.isActive)
        #expect(!right.channel.isActive)
    }

    @Test(.timeLimit(.minutes(1)))
    func deadlineClosesIdleEndpoints() async throws {
        let left = try await endpoint()
        let right = try await endpoint()
        await #expect(throws: DuplexByteRelay.Failure.deadlineExceeded) {
            try await DuplexByteRelay.run(left.stream, right.stream, deadline: .now.advanced(by: .milliseconds(20)), authorize: {})
        }
        #expect(!left.channel.isActive)
        #expect(!right.channel.isActive)
    }

    @Test(.timeLimit(.minutes(1)))
    func checksCurrentAuthorityBeforeForwarding() async throws {
        let left = try await endpoint()
        let right = try await endpoint()
        let authority = Authority()
        let task = Task {
            try await DuplexByteRelay.run(left.stream, right.stream, deadline: .now.advanced(by: .seconds(5)), authorize: { try authority.check() })
        }
        _ = try await left.channel.writeInbound(ByteBuffer(string: "allowed"))
        let allowed = try await right.channel.waitForOutboundWrite(as: ByteBuffer.self)
        #expect(String(buffer: allowed) == "allowed")
        authority.revoke()
        _ = try await left.channel.writeInbound(ByteBuffer(string: "denied"))
        await #expect(throws: Authority.Failure.revoked) { try await task.value }
        #expect(try await right.channel.readOutbound(as: ByteBuffer.self) == nil)
        #expect(!left.channel.isActive)
        #expect(!right.channel.isActive)
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsOversizedInputWithoutForwarding() async throws {
        let left = try await endpoint()
        let right = try await endpoint()
        let task = Task {
            try await DuplexByteRelay.run(left.stream, right.stream, deadline: .now.advanced(by: .seconds(5)), authorize: {})
        }
        _ = try await left.channel.writeInbound(ByteBuffer(repeating: 0, count: DuplexByteRelay.maximumChunkBytes + 1))
        await #expect(throws: DuplexByteRelay.Failure.chunkTooLarge) { try await task.value }
        #expect(try await right.channel.readOutbound(as: ByteBuffer.self) == nil)
    }

    private func endpoint(delayWrites: Bool = false) async throws -> Endpoint {
        let channel = NIOAsyncTestingChannel()
        let handler = OutputObserver(loop: channel.eventLoop, delayWrites: delayWrites)
        try await channel.pipeline.addHandler(handler).get()
        let stream = try await DuplexByteRelay.prepare(channel).get()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        return Endpoint(channel: channel, handler: handler, stream: stream)
    }

    private struct Endpoint: Sendable {
        let channel: NIOAsyncTestingChannel
        let handler: OutputObserver
        let stream: DuplexByteRelay.Endpoint
    }
}

private final class Authority: @unchecked Sendable {
    enum Failure: Error { case revoked }
    private let lock = NSLock()
    private var revoked = false
    func revoke() { lock.withLock { revoked = true } }
    func check() throws { try lock.withLock { if revoked { throw Failure.revoked } } }
}

/// Embedded channels do not implement half closure. Observe output EOF while
/// retaining the other direction, and optionally hold a write under backpressure.
private final class OutputObserver: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    let writeStarted: EventLoopPromise<Void>
    let outputClosed: EventLoopPromise<Void>
    private let delayWrites: Bool
    private var context: ChannelHandlerContext?
    private var pending: (NIOAny, EventLoopPromise<Void>?)?
    private var observedWrite = false
    var halfClosed = false

    init(loop: EventLoop, delayWrites: Bool) {
        self.delayWrites = delayWrites
        writeStarted = loop.makePromise()
        outputClosed = loop.makePromise()
    }
    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if !observedWrite { observedWrite = true; writeStarted.succeed(()) }
        if delayWrites { pending = (data, promise) }
        else { context.write(data, promise: promise) }
    }
    func completeWrite() {
        guard let (data, promise) = pending else { return }
        pending = nil
        context?.writeAndFlush(data, promise: promise)
    }
    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        if mode == .output {
            if !halfClosed { halfClosed = true; outputClosed.succeed(()) }
            promise?.succeed(())
        } else {
            pending?.1?.fail(ChannelError.ioOnClosedChannel)
            pending = nil
            if !observedWrite { observedWrite = true; writeStarted.fail(ChannelError.ioOnClosedChannel) }
            if !halfClosed { halfClosed = true; outputClosed.fail(ChannelError.ioOnClosedChannel) }
            context.close(mode: mode, promise: promise)
        }
    }
}
