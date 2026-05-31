#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH

/// Mobile-side client for the `pane-control@graftty.dev` SSH subsystem.
///
/// Opens a `.session` child channel via the parent `NIOSSHHandler`,
/// installs length-prefixed framing + an inbound relay, then issues a
/// `SubsystemRequest` for `SSHChannelTypeNames.paneControl` with
/// `wantReply: true`. If the server NACKs the subsystem (unknown name,
/// revoked client, etc.), `open()` throws — the alternative
/// (`wantReply: false`) would cause subsequent RPCs to hang forever.
///
/// One channel per `RemoteHostConnection`. Single in-flight RPC per
/// channel — clients serialise their own RPCs (parent design §8.1).
/// Production wraps this in `PaneControlClient` (Task 8) which is an
/// actor and serialises by construction.
public final class PaneControlChannelClient: @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case openFailed(any Error)
        case channelClosed
    }

    private let parentChannel: Channel
    private let parentHandler: NIOSSHHandler

    private let lock = NIOLock()
    private var childChannel: Channel?
    private var pending: CheckedContinuation<PaneControlResponse, Error>?
    private var closed = false

    public init(parentChannel: Channel, parentHandler: NIOSSHHandler) {
        self.parentChannel = parentChannel
        self.parentHandler = parentHandler
    }

    /// Opens the SSH session channel and sends the subsystem request.
    /// Resolves when the server ChannelSuccess-acknowledges the
    /// subsystem (wantReply: true).
    public func open() async throws {
        let promise = parentChannel.eventLoop.makePromise(of: Channel.self)
        parentHandler.createChannel(promise, channelType: .session) { [weak self] child, _ in
            guard let self else {
                return child.eventLoop.makeFailedFuture(ClientError.channelClosed)
            }
            do {
                try child.pipeline.syncOperations.addHandler(LengthPrefixedFraming.makeFrameDecoder())
                try child.pipeline.syncOperations.addHandler(LengthPrefixedFraming.makeFramePrepender())
                try child.pipeline.syncOperations.addHandler(InboundResponseRelay(owner: self))
                return child.eventLoop.makeSucceededVoidFuture()
            } catch {
                return child.eventLoop.makeFailedFuture(error)
            }
        }
        do {
            let child = try await promise.futureResult.get()
            lock.withLock { self.childChannel = child }
            let subsystem = SSHChannelRequestEvent.SubsystemRequest(
                subsystem: SSHChannelTypeNames.paneControl,
                wantReply: true
            )
            // triggerUserOutboundEvent with wantReply: true returns a
            // future that completes on ChannelSuccess (subsystem accepted)
            // or fails on ChannelFailure (unknown subsystem / refused).
            try await child.triggerUserOutboundEvent(subsystem).get()
            child.closeFuture.whenComplete { [weak self] _ in
                self?.handleChildClose()
            }
        } catch {
            throw ClientError.openFailed(error)
        }
    }

    public func send(_ request: PaneControlRequest) async throws -> PaneControlResponse {
        let child = lock.withLock { childChannel }
        guard let child else { throw ClientError.channelClosed }
        let body = try JSONEncoder().encode(request)
        let buf = child.allocator.buffer(bytes: body)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PaneControlResponse, Error>) in
            lock.withLock { pending = cont }
            child.writeAndFlush(buf).whenFailure { [weak self] error in
                self?.failPending(error)
            }
        }
    }

    public func close() {
        let child = lock.withLock { () -> Channel? in
            closed = true
            return childChannel
        }
        child?.close(promise: nil)
    }

    // MARK: - Inbound

    fileprivate func deliverInbound(_ bytes: Data) {
        let cont = lock.withLock { () -> CheckedContinuation<PaneControlResponse, Error>? in
            let snapshot = pending
            pending = nil
            return snapshot
        }
        guard let cont else { return }
        if let response = try? JSONDecoder().decode(PaneControlResponse.self, from: bytes) {
            cont.resume(returning: response)
        } else {
            cont.resume(returning: .error(code: "malformed-response", message: "decode failed"))
        }
    }

    private func failPending(_ error: any Error) {
        let cont = lock.withLock { () -> CheckedContinuation<PaneControlResponse, Error>? in
            let snapshot = pending
            pending = nil
            return snapshot
        }
        cont?.resume(throwing: error)
    }

    private func handleChildClose() {
        failPending(ClientError.channelClosed)
    }
}

private final class InboundResponseRelay: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    weak var owner: PaneControlChannelClient?

    init(owner: PaneControlChannelClient) { self.owner = owner }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        owner?.deliverInbound(Data(buf.readableBytesView))
    }
}
#endif
