import Foundation
import GrafttyProtocol
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// Client for the authenticated worktree-management subsystem.
public final class WorktreeManagementChannelClient: @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case openFailed(any Error)
        case channelClosed
        case subsystemRejected
        case busy
        case timedOut
    }

    private let parentChannel: Channel
    private let parentHandler: NIOSSHHandler
    private let lock = NIOLock()
    private var childChannel: Channel?
    private var subsystemReply: CheckedContinuation<Void, Error>?
    private var pending: CheckedContinuation<WorktreeManagementResponse, Error>?
    private var deadline: Scheduled<Void>?

    public init(parentChannel: Channel, parentHandler: NIOSSHHandler) {
        self.parentChannel = parentChannel
        self.parentHandler = parentHandler
    }

    public func open() async throws {
        do {
            let child = try await openChildChannel(
                parentChannel: parentChannel,
                parentHandler: parentHandler
            ) { [weak self] child, _ in
                guard let self else {
                    return child.eventLoop.makeFailedFuture(ClientError.channelClosed)
                }
                do {
                    try child.pipeline.syncOperations.addHandler(SSHChannelDataCodec())
                    try child.pipeline.syncOperations.addHandler(
                        LengthPrefixedFraming.makeFrameDecoder()
                    )
                    try child.pipeline.syncOperations.addHandler(
                        LengthPrefixedFraming.makeFramePrepender()
                    )
                    try child.pipeline.syncOperations.addHandler(
                        WorktreeManagementResponseRelay(owner: self)
                    )
                    try child.pipeline.syncOperations.addHandler(
                        WorktreeManagementSubsystemReplyRelay(owner: self)
                    )
                    return child.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return child.eventLoop.makeFailedFuture(error)
                }
            }
            lock.withLock { childChannel = child }
            child.closeFuture.whenComplete { [weak self] _ in
                self?.finishSubsystemReply(
                    .failure(ClientError.channelClosed)
                )
                self?.failPending(ClientError.channelClosed)
            }
            let request = SSHChannelRequestEvent.SubsystemRequest(
                subsystem: SSHChannelTypeNames.worktreeManagement,
                wantReply: true
            )
            try await withCheckedThrowingContinuation { continuation in
                let alreadyPending = lock.withLock {
                    guard subsystemReply == nil else { return true }
                    subsystemReply = continuation
                    return false
                }
                guard !alreadyPending else {
                    continuation.resume(throwing: ClientError.channelClosed)
                    return
                }
                child.triggerUserOutboundEvent(request).whenFailure {
                    [weak self] error in
                    self?.finishSubsystemReply(.failure(error))
                }
            }
        } catch {
            lock.withLock { childChannel }?.close(promise: nil)
            throw ClientError.openFailed(error)
        }
    }

    public func send(
        _ request: WorktreeManagementRequest
    ) async throws -> WorktreeManagementResponse {
        guard let child = lock.withLock({ childChannel }) else {
            throw ClientError.channelClosed
        }
        let body = try JSONEncoder().encode(request)
        let buffer = child.allocator.buffer(bytes: body)
        let loop = child.eventLoop
        return try await withCheckedThrowingContinuation { continuation in
            let busy = lock.withLock {
                if pending != nil { return true }
                pending = continuation
                return false
            }
            if busy {
                continuation.resume(throwing: ClientError.busy)
                return
            }
            let scheduled = loop.scheduleTask(in: .seconds(30)) { [weak self] () -> Void in
                self?.failPending(ClientError.timedOut)
            }
            lock.withLock { deadline = scheduled }
            child.writeAndFlush(buffer).whenFailure { [weak self] error in
                self?.failPending(error)
            }
        }
    }

    public func close() {
        lock.withLock { childChannel }?.close(promise: nil)
        finishSubsystemReply(.failure(ClientError.channelClosed))
        failPending(ClientError.channelClosed)
    }

    fileprivate func deliverSubsystemReply(accepted: Bool) {
        finishSubsystemReply(
            accepted
                ? .success(())
                : .failure(ClientError.subsystemRejected)
        )
    }

    fileprivate func deliver(_ bytes: Data) {
        let result = Result {
            try JSONDecoder().decode(WorktreeManagementResponse.self, from: bytes)
        }
        let continuation = lock.withLock {
            let continuation = pending
            pending = nil
            deadline?.cancel()
            deadline = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    private func failPending(_ error: any Error) {
        let continuation = lock.withLock {
            let continuation = pending
            pending = nil
            deadline?.cancel()
            deadline = nil
            return continuation
        }
        continuation?.resume(throwing: error)
    }

    private func finishSubsystemReply(_ result: Result<Void, Error>) {
        let continuation = lock.withLock {
            let continuation = subsystemReply
            subsystemReply = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private final class WorktreeManagementResponseRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let owner: WorktreeManagementChannelClient

    init(owner: WorktreeManagementChannelClient) {
        self.owner = owner
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        owner.deliver(Data(unwrapInboundIn(data).readableBytesView))
    }
}

private final class WorktreeManagementSubsystemReplyRelay:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer
    let owner: WorktreeManagementChannelClient

    init(owner: WorktreeManagementChannelClient) {
        self.owner = owner
    }

    func userInboundEventTriggered(
        context: ChannelHandlerContext,
        event: Any
    ) {
        if event is ChannelSuccessEvent {
            owner.deliverSubsystemReply(accepted: true)
        } else if event is ChannelFailureEvent {
            owner.deliverSubsystemReply(accepted: false)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

public protocol WorktreeManagementChannelDriver: Sendable {
    func open() async throws
    func send(
        _ request: WorktreeManagementRequest
    ) async throws -> WorktreeManagementResponse
    func close()
}

extension WorktreeManagementChannelClient: WorktreeManagementChannelDriver {}

public actor WorktreeManagementClient {
    private let driver: any WorktreeManagementChannelDriver

    public init(driver: any WorktreeManagementChannelDriver) {
        self.driver = driver
    }

    public func open() async throws {
        try await driver.open()
    }

    public func send(
        _ request: WorktreeManagementRequest
    ) async throws -> WorktreeManagementResponse {
        try await driver.send(request)
    }

    public func close() {
        driver.close()
    }
}
