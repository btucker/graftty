import Foundation
import GrafttyProtocol
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

struct WorktreeManagementRequestLifecycle: Sendable {
    enum BeginResult: Equatable, Sendable {
        case accepted(UInt64)
        case busy
        case closed
    }

    private enum State: Sendable {
        case ready
        case pending(UInt64)
        case closed
    }

    private var state: State = .ready
    private var nextRequestID: UInt64 = 0

    var isClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    func isPending(_ requestID: UInt64) -> Bool {
        if case .pending(let pendingID) = state {
            return pendingID == requestID
        }
        return false
    }

    mutating func begin() -> BeginResult {
        switch state {
        case .ready:
            nextRequestID &+= 1
            state = .pending(nextRequestID)
            return .accepted(nextRequestID)
        case .pending:
            return .busy
        case .closed:
            return .closed
        }
    }

    mutating func completeCurrent() -> Bool {
        guard case .pending = state else { return false }
        state = .ready
        return true
    }

    mutating func poison(_ requestID: UInt64) -> Bool {
        guard case .pending(let pendingID) = state,
              pendingID == requestID else {
            return false
        }
        state = .closed
        return true
    }

    mutating func close() {
        state = .closed
    }
}

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
    private let subsystemReplyTimeout: TimeAmount
    private let responseTimeout: TimeAmount
    private let lock = NIOLock()
    private var childChannel: Channel?
    private var subsystemReplyWaiter: SSHSubsystemReplyWaiter?
    private struct PendingRequest {
        let id: UInt64
        let continuation:
            CheckedContinuation<WorktreeManagementResponse, Error>
    }
    private var pending: PendingRequest?
    private var requestLifecycle =
        WorktreeManagementRequestLifecycle()
    private var deadline: Scheduled<Void>?

    public init(
        parentChannel: Channel,
        parentHandler: NIOSSHHandler,
        subsystemReplyTimeout: TimeAmount = .seconds(30),
        responseTimeout: TimeAmount = .seconds(30)
    ) {
        self.parentChannel = parentChannel
        self.parentHandler = parentHandler
        self.subsystemReplyTimeout = subsystemReplyTimeout
        self.responseTimeout = responseTimeout
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
            let replyWaiter = SSHSubsystemReplyWaiter()
            let acceptedChild = lock.withLock {
                guard !requestLifecycle.isClosed else { return false }
                childChannel = child
                subsystemReplyWaiter = replyWaiter
                return true
            }
            guard acceptedChild else {
                child.close(promise: nil)
                throw CancellationError()
            }
            child.closeFuture.whenComplete { [weak self] _ in
                self?.handleChildClose()
            }
            let request = SSHChannelRequestEvent.SubsystemRequest(
                subsystem: SSHChannelTypeNames.worktreeManagement,
                wantReply: true
            )
            try await replyWaiter.wait(
                scheduleTimeout: { callback in
                    let scheduled = child.eventLoop.scheduleTask(
                        in: self.subsystemReplyTimeout,
                        callback
                    )
                    return { scheduled.cancel() }
                },
                timeoutError: ClientError.timedOut,
                onAbort: {
                    child.close(promise: nil)
                },
                start: { [weak replyWaiter] in
                    child.triggerUserOutboundEvent(request).whenFailure {
                        error in
                        replyWaiter?.finish(.failure(error))
                    }
                }
            )
        } catch {
            let child = lock.withLock {
                requestLifecycle.close()
                return childChannel
            }
            child?.close(promise: nil)
            throw ClientError.openFailed(error)
        }
    }

    public func send(
        _ request: WorktreeManagementRequest
    ) async throws -> WorktreeManagementResponse {
        guard let child = lock.withLock({
            requestLifecycle.isClosed ? nil : childChannel
        }) else {
            throw ClientError.channelClosed
        }
        let body = try JSONEncoder().encode(request)
        let buffer = child.allocator.buffer(bytes: body)
        let loop = child.eventLoop
        return try await withCheckedThrowingContinuation { continuation in
            let registration = lock.withLock {
                guard childChannel != nil else {
                    return WorktreeManagementRequestLifecycle
                        .BeginResult.closed
                }
                let result = requestLifecycle.begin()
                guard case .accepted(let requestID) = result else {
                    return result
                }
                pending = PendingRequest(
                    id: requestID,
                    continuation: continuation
                )
                return result
            }
            guard case .accepted(let requestID) = registration else {
                switch registration {
                case .busy:
                    continuation.resume(throwing: ClientError.busy)
                case .closed:
                    continuation.resume(
                        throwing: ClientError.channelClosed
                    )
                case .accepted:
                    break
                }
                return
            }
            let scheduled = loop.scheduleTask(in: responseTimeout) {
                [weak self, weak child] () -> Void in
                guard let child else { return }
                self?.timeOutRequest(requestID, child: child)
            }
            let isPending = lock.withLock {
                guard requestLifecycle.isPending(requestID),
                      pending?.id == requestID else {
                    return false
                }
                deadline = scheduled
                return true
            }
            guard isPending else {
                scheduled.cancel()
                return
            }
            child.writeAndFlush(buffer).whenFailure { [weak self] error in
                self?.poisonRequest(
                    requestID,
                    error: error,
                    child: child
                )
            }
        }
    }

    public func close() {
        let child = lock.withLock {
            requestLifecycle.close()
            let child = childChannel
            childChannel = nil
            return child
        }
        child?.close(promise: nil)
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
        let continuation:
            CheckedContinuation<WorktreeManagementResponse, Error>? =
            lock.withLock {
                guard requestLifecycle.completeCurrent() else {
                    return nil
                }
                let continuation = pending?.continuation
                pending = nil
                deadline?.cancel()
                deadline = nil
                return continuation
            }
        continuation?.resume(with: result)
    }

    private func failPending(_ error: any Error) {
        let continuation = lock.withLock {
            let continuation = pending?.continuation
            pending = nil
            deadline?.cancel()
            deadline = nil
            return continuation
        }
        continuation?.resume(throwing: error)
    }

    private func finishSubsystemReply(_ result: Result<Void, Error>) {
        let waiter = lock.withLock { subsystemReplyWaiter }
        waiter?.finish(result)
    }

    private func handleChildClose() {
        lock.withLock {
            requestLifecycle.close()
            childChannel = nil
        }
        finishSubsystemReply(.failure(ClientError.channelClosed))
        failPending(ClientError.channelClosed)
    }

    private func timeOutRequest(_ requestID: UInt64, child: Channel) {
        poisonRequest(
            requestID,
            error: ClientError.timedOut,
            child: child
        )
    }

    private func poisonRequest(
        _ requestID: UInt64,
        error: any Error,
        child: Channel
    ) {
        let continuation:
            CheckedContinuation<WorktreeManagementResponse, Error>? =
            lock.withLock {
                guard pending?.id == requestID,
                      requestLifecycle.poison(requestID) else {
                    return nil
                }
                let continuation = pending?.continuation
                pending = nil
                deadline?.cancel()
                deadline = nil
                childChannel = nil
                return continuation
            }
        guard let continuation else { return }
        continuation.resume(throwing: error)
        child.close(promise: nil)
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
