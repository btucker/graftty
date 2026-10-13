import Foundation
import GrafttyProtocol
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH
import NIOExtras

/// Bounded typed RPCs on the authenticated Chrome subsystem.
public final class ChromeTabChannelClient: @unchecked Sendable {
    public enum ClientError: Error, Sendable { case channelClosed, busy, timedOut, unsupported }
    private let parentChannel: Channel
    private let parentHandler: NIOSSHHandler
    private let lock = NIOLock()
    private var childChannel: Channel?
    private var pending: SSHReplyWaiter<ChromeTabResponse>?
    private var subsystemReply: SSHSubsystemReplyWaiter?
    private var closed = false

    public init(parentChannel: Channel, parentHandler: NIOSSHHandler) {
        self.parentChannel = parentChannel; self.parentHandler = parentHandler
    }

    public func open() async throws {
        let waiter = SSHSubsystemReplyWaiter()
        let accepted = lock.withLock { () -> Bool in
            guard !closed, subsystemReply == nil, childChannel == nil else { return false }
            subsystemReply = waiter; return true
        }
        guard accepted else { throw ClientError.channelClosed }
        do {
            let child = try await openChildChannel(parentChannel: parentChannel, parentHandler: parentHandler) { [self] child, _ in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(SSHChannelDataCodec())
                    try child.pipeline.syncOperations.addHandler(ByteToMessageHandler(LengthFieldBasedFrameDecoder(lengthFieldLength: .four), maximumBufferSize: ChromeTabRequest.maximumResponseBytes + 4))
                    try child.pipeline.syncOperations.addHandler(LengthPrefixedFraming.makeFramePrepender())
                    try child.pipeline.syncOperations.addHandler(ChromeTabResponseRelay(owner: self))
                }
            }
            let acceptedChild = lock.withLock { () -> Bool in
                guard !closed else { return false }
                childChannel = child; return true
            }
            guard acceptedChild else { child.close(promise: nil); throw ClientError.channelClosed }
            child.closeFuture.whenComplete { [weak self] _ in self?.close() }
            try await waiter.wait(timeout: .seconds(30), timeoutError: ClientError.timedOut, onAbort: { [weak self] in self?.close() }) {
                child.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: SSHChannelTypeNames.chromeTabs, wantReply: true))
                    .whenFailure { waiter.finish(.failure($0)) }
            }
        } catch { close(); throw error }
    }

    public func send(_ request: ChromeTabRequest) async throws -> ChromeTabResponse {
        let body = try JSONEncoder().encode(request)
        guard body.count <= ChromeTabRequest.maximumRequestBytes else { throw ClientError.channelClosed }
        let waiter = SSHReplyWaiter<ChromeTabResponse>()
        let child = lock.withLock { () -> Channel? in
            guard !closed, pending == nil, let childChannel else { return nil }
            pending = waiter; return childChannel
        }
        guard let child else { throw lock.withLock { closed ? ClientError.channelClosed : ClientError.busy } }
        defer { lock.withLock { if pending === waiter { pending = nil } } }
        return try await waiter.wait(timeout: .seconds(30), timeoutError: ClientError.timedOut, onAbort: { [weak self] in self?.close() }) { [weak self] in
            child.writeAndFlush(child.allocator.buffer(bytes: body)).whenFailure { error in
                waiter.finish(.failure(error)); self?.close()
            }
        }
    }

    public func close() {
        let snapshot = lock.withLock { () -> (Channel?, SSHReplyWaiter<ChromeTabResponse>?, SSHSubsystemReplyWaiter?) in
            closed = true
            let value = (childChannel, pending, subsystemReply)
            childChannel = nil; pending = nil; subsystemReply = nil
            return value
        }
        snapshot.1?.finish(.failure(ClientError.channelClosed))
        snapshot.2?.finish(.failure(ClientError.channelClosed))
        snapshot.0?.close(promise: nil)
    }

    fileprivate func receive(_ bytes: Data) {
        guard let waiter = lock.withLock({ pending }) else { close(); return }
        do { waiter.finish(.success(try JSONDecoder().decode(ChromeTabResponse.self, from: bytes))) }
        catch { waiter.finish(.failure(error)); close() }
    }
    fileprivate func subsystemResult(_ accepted: Bool) {
        lock.withLock { subsystemReply }?.finish(accepted ? .success(()) : .failure(ClientError.unsupported))
    }
}

private final class ChromeTabResponseRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let owner: ChromeTabChannelClient
    init(owner: ChromeTabChannelClient) { self.owner = owner }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { owner.receive(Data(unwrapInboundIn(data).readableBytesView)) }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent: owner.subsystemResult(true)
        case is ChannelFailureEvent: owner.subsystemResult(false)
        default: context.fireUserInboundEventTriggered(event)
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { owner.close() }
}
