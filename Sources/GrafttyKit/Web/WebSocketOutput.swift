import Foundation
import NIO
import NIOWebSocket

/// Sends terminal bytes and control frames from producer threads to one client.
/// Reservations cover both event-loop tasks and incomplete socket writes.
/// Overflow closes this attachment instead of dropping bytes on an open stream.
final class WebSocketOutput: @unchecked Sendable {
    private weak var channel: Channel?
    private let lock = NSLock()
    private var pendingBytes = 0
    private var pendingFrames = 0
    private var stopped = false
    private static let byteLimit = 8 * 1024 * 1024
    private static let frameLimit = 1024

    init(channel: Channel) {
        self.channel = channel
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.stop(closeChannel: false)
        }
    }

    func send(_ data: Data, opcode: WebSocketOpcode) {
        guard let channel else { return }
        let count = data.count
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        guard count <= Self.byteLimit - pendingBytes,
              pendingFrames < Self.frameLimit else {
            stopped = true
            lock.unlock()
            channel.eventLoop.execute { channel.close(promise: nil) }
            return
        }
        pendingBytes += count
        pendingFrames += 1
        lock.unlock()

        channel.eventLoop.execute { [self] in
            lock.lock()
            let shouldWrite = !stopped
            lock.unlock()
            guard shouldWrite else { complete(count); return }
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let promise = channel.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete { [self] result in
                complete(count)
                if case .failure = result { stop(closeChannel: true) }
            }
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: opcode, data: buffer), promise: promise)
        }
    }

    private func complete(_ count: Int) {
        lock.lock()
        pendingBytes -= count
        pendingFrames -= 1
        lock.unlock()
    }

    private func stop(closeChannel: Bool) {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        if closeChannel, !wasStopped, let channel {
            channel.eventLoop.execute { channel.close(promise: nil) }
        }
    }
}
