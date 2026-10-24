import NIOCore

/// Relays already-authenticated byte channels. Callers own protocol framing,
/// permission revocation notifications, and any subprocess lifetime. Cancel the
/// relay when its delegation or connection is revoked, including while idle.
public enum DuplexByteRelay {
    public typealias Endpoint = NIOAsyncChannel<ByteBuffer, Never>
    public static let maximumChunkBytes = 64 * 1024

    public enum Failure: Error, Equatable {
        case deadlineExceeded
        case chunkTooLarge
    }

    /// Install from a channel initializer, before reads can arrive. The underlying
    /// transport must honor NIO read backpressure and deliver chunks no larger
    /// than maximumChunkBytes. SSH codecs belong before this handler.
    public static func prepare(_ channel: Channel) -> EventLoopFuture<Endpoint> {
        channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMapThrowing {
            try Endpoint(wrappingChannelSynchronously: channel,
                configuration: .init(backPressureStrategy: .init(lowWatermark: 1, highWatermark: 4)))
        }
    }

    /// Takes ownership of both channel lifetimes, including failure before the
    /// first byte. Authorization must be a short synchronous check of current
    /// authority. It runs before forwarding bytes in either direction.
    public static func run(
        _ left: Endpoint,
        _ right: Endpoint,
        deadline: ContinuousClock.Instant,
        authorize: @escaping @Sendable () throws -> Void
    ) async throws {
        let closeBoth: @Sendable () -> Void = {
            left.channel.close(promise: nil)
            right.channel.close(promise: nil)
        }
        try await withTaskCancellationHandler {
            try await left.executeThenClose { leftInput in
                try await right.executeThenClose { rightInput in
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { throw Failure.deadlineExceeded }
                    try authorize()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await forward(leftInput, to: right.channel, authorize: authorize) }
                        group.addTask { try await forward(rightInput, to: left.channel, authorize: authorize) }
                        group.addTask {
                            try await Task.sleep(until: deadline, clock: .continuous)
                            throw Failure.deadlineExceeded
                        }
                        do {
                            // The timer only throws. Two successful completions
                            // therefore mean both streams drained and sent EOF.
                            _ = try await group.next()
                            _ = try await group.next()
                            group.cancelAll()
                        } catch {
                            group.cancelAll()
                            // A cancelled EventLoopFuture.get() can remain
                            // suspended. Close before joining the other task so
                            // stalled writes and idle reads are released.
                            closeBoth()
                            throw error
                        }
                    }
                    try Task.checkCancellation()
                }
            }
        } onCancel: {
            closeBoth()
        }
    }

    private static func forward(
        _ input: NIOAsyncChannelInboundStream<ByteBuffer>,
        to destination: Channel,
        authorize: @Sendable () throws -> Void
    ) async throws {
        for try await bytes in input {
            try Task.checkCancellation()
            guard bytes.readableBytes <= maximumChunkBytes else { throw Failure.chunkTooLarge }
            try authorize()
            // Await the actual flush, not just an async writer's acceptance into
            // its queue. EOF must not discard a final pack or receiver response
            // when the destination is under backpressure.
            try await destination.writeAndFlush(bytes).get()
        }
        try Task.checkCancellation()
        try authorize()
        try await destination.close(mode: .output).get()
    }
}
