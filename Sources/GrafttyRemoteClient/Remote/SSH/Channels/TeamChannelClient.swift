import Foundation
import GrafttyProtocol
import NIOConcurrencyHelpers
import NIOCore
import NIOExtras
import NIOSSH

/// One duplex team RPC session on an already authenticated SSH connection.
public final class TeamChannelClient: @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case channelClosed, subsystemRejected, timedOut, alreadyOpened
    }

    private let parentChannel: Channel
    private let parentHandler: NIOSSHHandler
    private let handler: TeamRPCSession.Handler
    private let onClose: @Sendable () async -> Void
    private let lock = NIOLock()
    private var childChannel: Channel?
    private var session: TeamRPCSession?
    private let waiter = SSHSubsystemReplyWaiter()
    private var opened = false
    private var closed = false

    public init(
        parentChannel: Channel,
        parentHandler: NIOSSHHandler,
        handler: @escaping TeamRPCSession.Handler,
        onClose: @escaping @Sendable () async -> Void = {}
    ) {
        self.parentChannel = parentChannel
        self.parentHandler = parentHandler
        self.handler = handler
        self.onClose = onClose
    }

    public func open() async throws {
        try lock.withLock {
            guard !closed else { throw ClientError.channelClosed }
            guard !opened else { throw ClientError.alreadyOpened }
            opened = true
        }
        do {
            let child = try await openChildChannel(parentChannel: parentChannel, parentHandler: parentHandler) { [weak self] child, _ in
                guard let self else { return child.eventLoop.makeFailedFuture(ClientError.channelClosed) }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(SSHChannelDataCodec())
                    try child.pipeline.syncOperations.addHandler(ByteToMessageHandler(LengthFieldBasedFrameDecoder(lengthFieldLength: .four), maximumBufferSize: TeamRPCSession.maximumEnvelopeBytes))
                    try child.pipeline.syncOperations.addHandler(LengthPrefixedFraming.makeFramePrepender())
                    try child.pipeline.syncOperations.addHandler(TeamChannelRelay(owner: self))
                }
            }
            let session = TeamRPCSession(handler: handler, writer: { [weak child] bytes in
                guard let child, child.isActive else { throw ClientError.channelClosed }
                try await child.writeAndFlush(child.allocator.buffer(bytes: bytes)).get()
            }, onClose: { [weak child] in
                child?.close(promise: nil)
            })
            let accepted = lock.withLock {
                guard !closed else { return false }
                self.childChannel = child
                self.session = session
                return true
            }
            guard accepted else {
                await session.close()
                child.close(promise: nil)
                throw ClientError.channelClosed
            }
            child.closeFuture.whenComplete { [weak self] _ in self?.close() }
            try await waiter.wait(
                scheduleTimeout: { callback in
                    let deadline = child.eventLoop.scheduleTask(in: .seconds(30), callback)
                    return { deadline.cancel() }
                },
                timeoutError: ClientError.timedOut,
                onAbort: { child.close(promise: nil) },
                start: { [waiter] in
                    child.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: SSHChannelTypeNames.team, wantReply: true)).whenFailure { waiter.finish(.failure($0)) }
                }
            )
            guard !lock.withLock({ closed }) else { throw ClientError.channelClosed }
        } catch {
            close()
            throw error
        }
    }

    public func send(_ payload: Data) async throws -> Data {
        guard let session = lock.withLock({ closed ? nil : session }) else { throw ClientError.channelClosed }
        return try await session.send(payload)
    }

    public func close() {
        let state = lock.withLock { () -> (Channel?, TeamRPCSession?)? in
            guard !closed else { return nil }
            closed = true
            let state = (childChannel, session)
            childChannel = nil
            session = nil
            return state
        }
        guard let state else { return }
        waiter.finish(.failure(ClientError.channelClosed))
        state.0?.close(promise: nil)
        Task { [onClose] in
            await state.1?.close()
            await onClose()
        }
    }

    fileprivate func receive(_ bytes: Data) {
        guard let session = lock.withLock({ session }) else { return }
        Task { await session.receive(bytes) }
    }

    fileprivate func subsystemReply(accepted: Bool) {
        waiter.finish(accepted ? .success(()) : .failure(ClientError.subsystemRejected))
    }
}

private final class TeamChannelRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private weak var owner: TeamChannelClient?
    init(owner: TeamChannelClient) { self.owner = owner }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        owner?.receive(Data(unwrapInboundIn(data).readableBytesView))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent { owner?.subsystemReply(accepted: true) }
        else if event is ChannelFailureEvent { owner?.subsystemReply(accepted: false) }
        else { context.fireUserInboundEventTriggered(event) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        owner?.close()
        context.close(promise: nil)
    }
}
