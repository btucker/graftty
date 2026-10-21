import NIOCore
import NIOSSH

/// One-shot handler that resolves `waiter` with the peer's reply to a
/// `SubsystemRequest(wantReply: true)`, then removes itself so later
/// channel traffic flows past untouched.
final class SubsystemAckRelay: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    private let waiter: SSHSubsystemReplyWaiter
    private let rejected: any Error
    private let closed: any Error

    init(waiter: SSHSubsystemReplyWaiter, rejected: any Error, closed: any Error) {
        self.waiter = waiter
        self.rejected = rejected
        self.closed = closed
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            waiter.finish(.success(()))
            context.pipeline.removeHandler(self, promise: nil)
        } else if event is ChannelFailureEvent {
            waiter.finish(.failure(rejected))
            context.pipeline.removeHandler(self, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        waiter.finish(.failure(closed))
        context.fireChannelInactive()
    }
}

/// Sends `SubsystemRequest(subsystem, wantReply: true)` on `child` and waits
/// for the reply that a `SubsystemAckRelay` bound to `waiter` observes,
/// closing `child` if the deadline passes or the caller is cancelled.
func requestSubsystem(
    _ subsystem: String,
    on child: Channel,
    waiter: SSHSubsystemReplyWaiter,
    timeout: Duration,
    timeoutError: any Error
) async throws {
    try await waiter.wait(
        timeout: timeout,
        timeoutError: timeoutError,
        onAbort: { child.close(promise: nil) },
        start: {
            child.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(
                subsystem: subsystem, wantReply: true
            )).whenFailure { waiter.finish(.failure($0)) }
        }
    )
}
