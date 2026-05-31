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
        let loop = context.eventLoop
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
                // Marshal back to the event loop thread before writing —
                // mirrors the TerminalSessionHandler pattern so EmbeddedChannel
                // tests stay thread-safe.
                loop.execute {
                    channel.writeAndFlush(buf, promise: nil)
                }
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
