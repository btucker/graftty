import Foundation
import NIO
import NIOEmbedded
import NIOPosix
import NIOWebSocket
import Testing
@testable import GrafttyKit

@Suite("WebSocket terminal output")
struct WebSocketOutputTests {
    @Test("@spec WEB-4.11: If a WebSocket terminal client cannot drain output, then the application shall bound queued output to 8 MiB of payload and 1024 frames per connection, including work awaiting its event loop, and disconnect that client on overflow without silently dropping terminal bytes on an open connection.")
    func stalledSocketDisconnectsWithinBudget() throws {
        let sink = StalledWebSocketWrites()
        let channel = EmbeddedChannel(handler: sink)
        let output = WebSocketOutput(channel: channel)
        defer { _ = try? channel.finish() }

        // A transport which never completes writes models a stopped receiver.
        // Fixed input is just over the budget, never an exhaustion test.
        for _ in 0..<1100 {
            output.send(Data(repeating: 0x61, count: 8192), opcode: .binary)
            channel.embeddedEventLoop.run()
        }
        #expect(sink.peakBytes <= 8 * 1024 * 1024)
        #expect(sink.peakFrames <= 1024)
        #expect(sink.closeCount == 1)
        let retainedFrames = sink.frames.count
        #expect(retainedFrames == 0)
    }

    @Test func blockedEventLoopAlsoHasABudget() throws {
        let sink = StalledWebSocketWrites()
        let channel = EmbeddedChannel(handler: sink)
        let output = WebSocketOutput(channel: channel)
        defer { _ = try? channel.finish() }
        for _ in 0..<1100 {
            output.send(Data(repeating: 0x62, count: 8192), opcode: .binary)
        }
        channel.embeddedEventLoop.run()
        #expect(sink.peakBytes <= 8 * 1024 * 1024)
        #expect(sink.closeCount == 1)
        let retainedFrames = sink.frames.count
        #expect(retainedFrames == 0)
    }

    @Test func completedWritesReleaseBudgetAndPreserveOrder() throws {
        let sink = StalledWebSocketWrites()
        let channel = EmbeddedChannel(handler: sink)
        let output = WebSocketOutput(channel: channel)
        defer { _ = try? channel.finish() }
        // Send more than the lifetime budget. Each completed batch must
        // release its reservation, with text interleaved among binary bytes.
        for batch in 0..<3 {
            for index in 0..<512 {
                let byte = UInt8(truncatingIfNeeded: batch * 512 + index)
                output.send(Data(repeating: byte, count: 8192), opcode: index % 17 == 0 ? .text : .binary)
            }
            channel.embeddedEventLoop.run()
            let frames = sink.succeedWrites()
            #expect(frames.count == 512)
            for (index, frame) in frames.enumerated() {
                let byte = UInt8(truncatingIfNeeded: batch * 512 + index)
                #expect(frame.opcode == (index % 17 == 0 ? .text : .binary))
                #expect(frame.data.readableBytes == 8192)
                let bytesMatch = frame.data.readableBytesView.allSatisfy { $0 == byte }
                #expect(bytesMatch)
            }
        }
        #expect(sink.closeCount == 0)
    }

    @Test func smallControlFramesCannotBypassFrameLimit() throws {
        let sink = StalledWebSocketWrites()
        let channel = EmbeddedChannel(handler: sink)
        let output = WebSocketOutput(channel: channel)
        defer { _ = try? channel.finish() }
        for _ in 0..<1100 {
            output.send(Data([0x61]), opcode: .text)
            channel.embeddedEventLoop.run()
        }
        #expect(sink.peakFrames <= 1024)
        #expect(sink.closeCount == 1)
        let retainedFrames = sink.frames.count
        #expect(retainedFrames == 0)
    }

    @Test func cumulativeBytesAreBoundedBelowTheFrameLimit() throws {
        let sink = StalledWebSocketWrites()
        let channel = EmbeddedChannel(handler: sink)
        let output = WebSocketOutput(channel: channel)
        defer { _ = try? channel.finish() }
        for _ in 0..<5 {
            output.send(Data(repeating: 0x61, count: 2 * 1024 * 1024), opcode: .binary)
            channel.embeddedEventLoop.run()
        }
        #expect(sink.peakBytes == 8 * 1024 * 1024)
        #expect(sink.peakFrames == 4)
        #expect(sink.closeCount == 1)
        let retainedFrames = sink.frames.count
        #expect(retainedFrames == 0)
    }

    @Test func oversizedFrameIsRejectedBeforeQueueing() throws {
        let sink = StalledWebSocketWrites()
        let channel = EmbeddedChannel(handler: sink)
        let output = WebSocketOutput(channel: channel)
        defer { _ = try? channel.finish() }
        output.send(Data(repeating: 0x61, count: 8 * 1024 * 1024 + 1), opcode: .binary)
        channel.embeddedEventLoop.run()
        #expect(sink.peakBytes == 0)
        #expect(sink.closeCount == 1)
    }

    @Test func disconnectReleasesPendingOutputAndRejectsLateCallbacks() throws {
        let sink = StalledWebSocketWrites()
        let channel = EmbeddedChannel(handler: sink)
        let output = WebSocketOutput(channel: channel)
        output.send(Data("queued".utf8), opcode: .binary)
        try channel.close().wait()
        output.send(Data("late".utf8), opcode: .text)
        channel.embeddedEventLoop.run()
        #expect(sink.peakBytes == 0)
        let retainedFrames = sink.frames.count
        #expect(retainedFrames == 0)
        #expect(sink.closeCount == 1)
    }

    @Test func writeFailureDisconnectsAndReleasesWriter() throws {
        let sink = StalledWebSocketWrites()
        let channel = EmbeddedChannel(handler: sink)
        var output: WebSocketOutput? = WebSocketOutput(channel: channel)
        weak var weakOutput = output
        defer { weakOutput = nil }
        output?.send(Data("queued".utf8), opcode: .binary)
        channel.embeddedEventLoop.run()
        sink.failWrites()
        channel.embeddedEventLoop.run()
        #expect(sink.closeCount == 1)
        output?.send(Data("late".utf8), opcode: .binary)
        output = nil
        channel.embeddedEventLoop.run()
        #expect(weakOutput == nil)
        let retainedFrames = sink.frames.count
        #expect(retainedFrames == 0)
    }

    @Test func concurrentProducersDisconnectANonReadingTCPSocket() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let accepted = group.next().makePromise(of: Channel.self)
        let listener = try ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.socketOption(.so_sndbuf), value: 4096)
            .childChannelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder())
                    accepted.succeed(channel)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    accepted.fail(error)
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }.bind(host: "127.0.0.1", port: 0).wait()
        defer { try? listener.close().wait() }
        let port = try #require(listener.localAddress?.port)
        let client = try ClientBootstrap(group: group)
            .connectTimeout(.seconds(2))
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.socketOption(.so_rcvbuf), value: 4096)
            .connect(host: "127.0.0.1", port: port).wait()
        defer { try? client.close().wait() }
        let server = try accepted.futureResult.wait()
        let deadline = OutputTestDeadline()
        let timeout = server.eventLoop.scheduleTask(in: .seconds(5)) {
            deadline.fire()
            server.close(promise: nil)
        }
        defer { timeout.cancel() }
        let output = WebSocketOutput(channel: server)
        // Exactly 16 MiB total. A real receiver leaves autoRead disabled;
        // eight callback threads compete with socket completion callbacks.
        DispatchQueue.concurrentPerform(iterations: 8) { producer in
            for _ in 0..<64 {
                output.send(Data(repeating: UInt8(producer), count: 32 * 1024), opcode: .binary)
            }
        }
        try server.closeFuture.wait()
        timeout.cancel()
        #expect(!deadline.didFire)
    }
}

private final class OutputTestDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
    func fire() {
        lock.lock()
        fired = true
        lock.unlock()
    }
}

private final class StalledWebSocketWrites: ChannelOutboundHandler {
    typealias OutboundIn = WebSocketFrame
    var frames: [WebSocketFrame] = []
    var promises: [EventLoopPromise<Void>] = []
    var peakBytes = 0
    var peakFrames = 0
    var closeCount = 0
    private var bytes = 0

    func succeedWrites() -> [WebSocketFrame] {
        let result = frames
        frames.removeAll()
        bytes = 0
        let pending = promises
        promises.removeAll()
        for pending in pending { pending.succeed(()) }
        return result
    }

    func failWrites() {
        frames.removeAll()
        bytes = 0
        let pending = promises
        promises.removeAll()
        for pending in pending { pending.fail(ChannelError.ioOnClosedChannel) }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard closeCount == 0 else {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }
        let frame = unwrapOutboundIn(data)
        frames.append(frame)
        if let promise { promises.append(promise) }
        bytes += frame.data.readableBytes
        peakBytes = max(peakBytes, bytes)
        peakFrames = max(peakFrames, frames.count)
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        closeCount += 1
        context.close(mode: mode, promise: promise)
        failWrites()
    }
}
