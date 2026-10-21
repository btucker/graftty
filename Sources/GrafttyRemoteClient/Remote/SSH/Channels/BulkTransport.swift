import GrafttyProtocol
import NIOCore
import NIOSSH

/// The versioned subsystem is an authenticated capability probe. Old hosts
/// reject this child channel without disturbing the existing SSH connection.
func openBulkSubsystem(
    parentChannel: Channel, parentHandler: NIOSSHHandler,
    subsystem: String = GrafttyWebRTC.bulkSubsystem,
    initializer: @escaping @Sendable (Channel, SSHChannelType) -> EventLoopFuture<Void> = {
        channel, _ in channel.eventLoop.makeSucceededVoidFuture()
    }
) async throws -> Channel {
    let waiter = SSHSubsystemReplyWaiter()
    let child = try await openChildChannel(
        parentChannel: parentChannel, parentHandler: parentHandler,
        timeout: .seconds(5), closeParentOnTimeout: false
    ) { child, type in
        initializer(child, type).flatMap {
            child.pipeline.addHandler(SubsystemAckRelay(
                waiter: waiter,
                rejected: TerminalSessionClient.ClientError.pagingUnsupported,
                closed: TerminalSessionClient.ClientError.channelClosed
            ))
        }
    }
    do {
        try await requestSubsystem(
            subsystem, on: child, waiter: waiter,
            timeout: .seconds(5), timeoutError: TerminalSessionClient.ClientError.channelClosed
        )
        return child
    } catch {
        child.close(promise: nil)
        throw error
    }
}
