import Foundation
import GrafttyProtocol
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// One duplex RPC session on an already authenticated SSH connection.
/// Team and Git control use distinct subsystem names and callbacks.
public final class TeamChannelClient: @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case channelClosed, subsystemRejected, timedOut, alreadyOpened
    }

    private let subsystemName: String
    private let parentChannel: Channel
    private let parentHandler: NIOSSHHandler
    private let handler: TeamRPCSession.Handler
    private let onClose: @Sendable () async -> Void
    private let openTimeout: Duration
    private let lock = NIOLock()
    private var childChannel: Channel?
    private var session: TeamRPCSession?
    private let waiter = SSHSubsystemReplyWaiter()
    private var opened = false
    private var closed = false

    public init(
        parentChannel: Channel,
        parentHandler: NIOSSHHandler,
        subsystemName: String = SSHChannelTypeNames.team,
        handler: @escaping TeamRPCSession.Handler,
        onClose: @escaping @Sendable () async -> Void = {},
        openTimeout: Duration = .seconds(30)
    ) {
        self.subsystemName = subsystemName
        self.parentChannel = parentChannel
        self.parentHandler = parentHandler
        self.handler = handler
        self.onClose = onClose
        self.openTimeout = openTimeout
    }

    public func open() async throws {
        try lock.withLock {
            guard !closed else { throw ClientError.channelClosed }
            guard !opened else { throw ClientError.alreadyOpened }
            opened = true
        }
        do {
            try await waiter.wait(
                timeout: openTimeout,
                timeoutError: ClientError.timedOut,
                onAbort: { [weak self] in self?.close() },
                start: { [weak self] in self?.startOpening() }
            )
            guard !lock.withLock({ closed }) else { throw ClientError.channelClosed }
        } catch {
            close()
            throw error
        }
    }

    private func startOpening() {
        makeChildChannel(
            parentChannel: parentChannel,
            parentHandler: parentHandler
        ) { [weak self] child, _ in
            guard let self else { return child.eventLoop.makeFailedFuture(ClientError.channelClosed) }
            return child.eventLoop.makeCompletedFuture {
                let accepted = self.lock.withLock {
                    guard !self.closed else { return false }
                    self.childChannel = child
                    return true
                }
                guard accepted else { throw ClientError.channelClosed }
                child.closeFuture.whenComplete { [weak self] _ in self?.close() }
                try installSubsystemPipeline(
                    on: child,
                    maximumBufferSize: TeamRPCSession.maximumEnvelopeBytes,
                    relay: FrameRelay(
                        onFrame: { [weak self] in self?.receive($0) },
                        onError: { [weak self] _ in self?.close() }
                    ),
                    ack: SubsystemAckRelay(
                        waiter: self.waiter,
                        rejected: ClientError.subsystemRejected,
                        closed: ClientError.channelClosed
                    )
                )
            }
        }.whenComplete { [weak self] result in
            switch result {
            case .success(let child):
                guard let self else {
                    child.close(promise: nil)
                    return
                }
                self.requestSubsystem(on: child)
            case .failure(let error): self?.waiter.finish(.failure(error))
            }
        }
    }

    private func requestSubsystem(on child: Channel) {
        let session = TeamRPCSession(handler: handler, writer: { [weak child] bytes in
            guard let child, child.isActive else { throw ClientError.channelClosed }
            try await child.writeAndFlush(child.allocator.buffer(bytes: bytes)).get()
        }, onClose: { [weak child] in
            child?.close(promise: nil)
        })
        let accepted = lock.withLock {
            guard !closed else { return false }
            self.session = session
            return true
        }
        guard accepted else {
            Task { await session.close() }
            child.close(promise: nil)
            return
        }
        child.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: subsystemName, wantReply: true))
            .whenFailure { [waiter] in waiter.finish(.failure($0)) }
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

    private func receive(_ bytes: Data) {
        guard let session = lock.withLock({ session }) else { return }
        Task { await session.receive(bytes) }
    }
}
