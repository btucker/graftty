import NIOCore
import NIOSSH

final class PagedSubsystemReplyRelay: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    private let waiter: SSHSubsystemReplyWaiter

    init(waiter: SSHSubsystemReplyWaiter) { self.waiter = waiter }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            waiter.finish(.success(()))
            context.pipeline.removeHandler(self, promise: nil)
        } else if event is ChannelFailureEvent {
            waiter.finish(.failure(TerminalSessionClient.ClientError.pagingUnsupported))
            context.pipeline.removeHandler(self, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        waiter.finish(.failure(TerminalSessionClient.ClientError.channelClosed))
        context.fireChannelInactive()
    }
}
