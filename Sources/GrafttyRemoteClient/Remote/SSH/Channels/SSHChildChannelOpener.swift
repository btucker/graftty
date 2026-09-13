import NIOCore
import NIOSSH

enum SSHChildChannelOpenError: Error, Equatable {
    case timedOut
}

/// Opens an SSH child channel on `parentChannel` and returns it once NIOSSH's
/// `createChannel` promise resolves.
///
/// `NIOSSHHandler.createChannel` must run on the parent channel's own event
/// loop: once the SSH handshake is already settled, it can synchronously
/// drain the multiplexer's pending-channel queue
/// (`createPendingChannelsIfPossible`), which touches
/// `ChannelHandlerContext.channel` and asserts it's on-loop. A *first*
/// channel opened while the handshake is still settling gets queued and
/// drained later from the loop itself, masking this requirement — but a
/// *second* child channel opened on the same connection after the handshake
/// has completed calls straight into that synchronous drain from whatever
/// thread this function was invoked on (an arbitrary Swift Concurrency
/// thread), crashing with `preconditionInEventLoop`. Routing the call
/// through `parentChannel.eventLoop.execute` fixes this for every caller,
/// not just the multi-channel case — all three of `TerminalSessionClient`,
/// `PaneControlChannelClient`, and `PanesStateChannelClient` used to
/// duplicate this exact dance (and comment) before opening their own child
/// channel; they now share this one implementation.
///
/// Per-caller concerns — pipeline setup beyond `initializer`, subsystem
/// requests, shell/pty handshakes, and error translation into a caller's own
/// `ClientError` — stay with each call site.
func openChildChannel(
    parentChannel: Channel,
    parentHandler: NIOSSHHandler,
    channelType: SSHChannelType = .session,
    timeout: Duration = .seconds(10),
    initializer: @escaping @Sendable (Channel, SSHChannelType) -> EventLoopFuture<Void>
) async throws -> Channel {
    try Task.checkCancellation()
    // `NIOSSHHandler` isn't `Sendable`, but the only thread-safety
    // requirement `createChannel` has is running on the parent channel's
    // own event loop — the executor hop above is what makes that safe, not
    // anything about which thread carries the handler reference there.
    // Every one of this helper's three callers used to satisfy the
    // `@Sendable` closure checker by capturing `self` (a class, hence
    // `@unchecked Sendable`) instead of the handler directly; a free
    // function has no `self` to lean on, so this box plays that role.
    let handlerBox = UncheckedSendableBox(value: parentHandler)
    let waiter = SSHReplyWaiter<Channel>()
    // Keep NIOSSH's promise separate from the deadline. NIOSSH still owns
    // its completion if the peer responds after the caller has timed out.
    return try await waiter.wait(
        timeout: timeout,
        timeoutError: SSHChildChannelOpenError.timedOut,
        onAbort: { parentChannel.close(promise: nil) },
        // A dismissed preview can cancel an open on a healthy connection.
        // Preserve its siblings; the completion handler closes any late child.
        onCancel: {},
        start: {
            parentChannel.eventLoop.execute {
                let promise = parentChannel.eventLoop.makePromise(of: Channel.self)
                promise.futureResult.whenComplete { result in
                    if !waiter.finish(result),
                       case .success(let child) = result {
                        child.close(promise: nil)
                    }
                }
                guard parentChannel.isActive else {
                    promise.fail(ChannelError.ioOnClosedChannel)
                    return
                }
                handlerBox.value.createChannel(promise, channelType: channelType, initializer)
            }
        }
    )
}

private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}
