import Foundation
import GrafttyKit
import GrafttyProtocol
import NIOConcurrencyHelpers
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
///
/// Concurrency: `@unchecked Sendable` because all mutable state
/// (`isInactive`, `cancellable`) is guarded by `lock`.
public final class PanesStateChannelHandler: ChannelInboundHandler, @unchecked Sendable {
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
    private let lock = NIOLock()
    private var isInactive = false
    /// Idempotency flag for `startSubscription`. `handlerAdded` and
    /// `channelActive` both call it on the same handler instance in some
    /// installation orders; without this guard, two subscriptions would
    /// run concurrently and the second `storeCancellable` would overwrite
    /// the first cancellable, leaking the first subscription.
    private var started = false
    private var cancellable: Cancellable?

    public init(subscribe: @escaping Subscribe) {
        self.subscribe = subscribe
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        // If the channel is already active (i.e. we were installed after
        // channelActive fired — the normal case when SubsystemDispatcher
        // routes a subsystem request on an already-active channel), start
        // the subscription immediately. NIO won't re-fire channelActive
        // for handlers added to an already-active pipeline.
        if context.channel.isActive {
            startSubscription(context: context)
        }
    }

    public func channelActive(context: ChannelHandlerContext) {
        startSubscription(context: context)
        context.fireChannelActive()
    }

    private func startSubscription(context: ChannelHandlerContext) {
        let shouldStart: Bool = lock.withLock {
            if started || isInactive { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        let channel = context.channel
        let loop = context.eventLoop
        let allocator = context.channel.allocator
        let subscribe = self.subscribe
        let storeCancellable: @Sendable (Cancellable) -> Void = { [weak self] c in
            guard let self else { c.cancel(); return }
            let shouldCancel: Bool = self.lock.withLock {
                if self.isInactive { return true }
                self.cancellable = c
                return false
            }
            if shouldCancel { c.cancel() }
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
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // `panes-state@graftty.dev` is server-pushed; clients should not write
        // payload frames. Silently drop — parent design §8.1 ("Server pushes
        // length-prefixed JSON ... envelopes").
    }

    public func channelInactive(context: ChannelHandlerContext) {
        let c = lock.withLock { () -> Cancellable? in
            isInactive = true
            let snapshot = cancellable
            cancellable = nil
            return snapshot
        }
        c?.cancel()
        context.fireChannelInactive()
    }
}
