import Foundation
import GrafttyProtocol
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH

/// Client-side endpoint for the `pane-control@graftty.dev` SSH subsystem.
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
        /// A `send(_:)` call was issued while another RPC was already
        /// in flight. The wrapping `PaneControlClient` is an actor but
        /// actors are reentrant at await boundaries — a concurrent caller
        /// can re-enter the actor while a prior `driver.send` is suspended.
        /// We return this soft error rather than crashing on a precondition.
        case busy
        /// The RPC didn't receive a response within `rpcDeadline`. The host
        /// is presumed wedged (mutator deadlock, etc.); the channel is
        /// left open so subsequent RPCs can attempt to make progress.
        case timedOut
    }

    /// Per-RPC deadline. If the host doesn't respond within this window we
    /// fail the continuation with `.timedOut`; otherwise a hung mutator
    /// would park the caller forever and the next RPC would trip the
    /// `.busy` path.
    public static let rpcDeadline: Duration = .seconds(30)

    private let parentChannel: Channel
    private let parentHandler: NIOSSHHandler

    private let lock = NIOLock()
    private var childChannel: Channel?
    private var pending: CheckedContinuation<PaneControlResponse, Error>?
    private var deadline: Scheduled<Void>?
    private var closed = false

    public init(parentChannel: Channel, parentHandler: NIOSSHHandler) {
        self.parentChannel = parentChannel
        self.parentHandler = parentHandler
    }

    /// Opens the SSH session channel and sends the subsystem request.
    /// Resolves when the server ChannelSuccess-acknowledges the
    /// subsystem (wantReply: true).
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
                    // SSHChannelDataCodec bridges SSHChannelData ↔ ByteBuffer
                    // so the downstream framing handlers operate on raw bytes.
                    try child.pipeline.syncOperations.addHandler(SSHChannelDataCodec())
                    try child.pipeline.syncOperations.addHandler(LengthPrefixedFraming.makeFrameDecoder())
                    try child.pipeline.syncOperations.addHandler(LengthPrefixedFraming.makeFramePrepender())
                    try child.pipeline.syncOperations.addHandler(InboundResponseRelay(owner: self))
                    return child.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return child.eventLoop.makeFailedFuture(error)
                }
            }
            lock.withLock { self.childChannel = child }
            // Register the close handler IMMEDIATELY — before the subsystem
            // request — so a partial-open failure still propagates onClosed
            // (and fails any pending RPC). Without this, a NACK after the
            // child opens would leak the half-open channel.
            child.closeFuture.whenComplete { [weak self] _ in
                self?.handleChildClose()
            }
            let subsystem = SSHChannelRequestEvent.SubsystemRequest(
                subsystem: SSHChannelTypeNames.paneControl,
                wantReply: true
            )
            // triggerUserOutboundEvent with wantReply: true returns a
            // future that completes on ChannelSuccess (subsystem accepted)
            // or fails on ChannelFailure (unknown subsystem / refused).
            try await child.triggerUserOutboundEvent(subsystem).get()
        } catch {
            // Defense-in-depth: if the open failed after we stashed
            // childChannel, make sure the half-open channel is torn down.
            let child = lock.withLock { childChannel }
            child?.close(promise: nil)
            throw ClientError.openFailed(error)
        }
    }

    public func send(_ request: PaneControlRequest) async throws -> PaneControlResponse {
        let child = lock.withLock { childChannel }
        guard let child else { throw ClientError.channelClosed }
        let body = try JSONEncoder().encode(request)
        let buf = child.allocator.buffer(bytes: body)
        // Schedule a deadline on the channel's event loop. If it fires
        // before deliverInbound/failPending resolves the pending continuation,
        // we fail it with `.timedOut` so callers don't hang forever on a
        // wedged host mutator. Without this, the next RPC would trip the
        // `.busy` path forever.
        let loop = child.eventLoop
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PaneControlResponse, Error>) in
            // Reentrancy guard: `PaneControlClient` is an actor but actors
            // are reentrant at awaits, so a concurrent caller CAN re-enter
            // this method while a prior call is suspended. Return a soft
            // `.busy` instead of crashing on a precondition.
            let isBusy: Bool = self.lock.withLock {
                if self.pending != nil { return true }
                self.pending = cont
                return false
            }
            if isBusy {
                cont.resume(throwing: ClientError.busy)
                return
            }
            let deadline = loop.scheduleTask(in: .seconds(30)) { [weak self] () -> Void in
                self?.failPending(ClientError.timedOut)
            }
            self.lock.withLock { self.deadline = deadline }
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
            self.deadline?.cancel()
            self.deadline = nil
            return snapshot
        }
        guard let cont else { return }
        do {
            let response = try JSONDecoder().decode(PaneControlResponse.self, from: bytes)
            cont.resume(returning: response)
        } catch {
            cont.resume(returning: .error(code: "malformed-response", message: String(describing: error)))
        }
    }

    private func failPending(_ error: any Error) {
        let cont = lock.withLock { () -> CheckedContinuation<PaneControlResponse, Error>? in
            let snapshot = pending
            pending = nil
            self.deadline?.cancel()
            self.deadline = nil
            return snapshot
        }
        cont?.resume(throwing: error)
    }

    private func handleChildClose() {
        failPending(ClientError.channelClosed)
    }
}

/// Inbound relay installed on the SSH child channel. Forwards inbound
/// `ByteBuffer` frames to the owning `PaneControlChannelClient`.
///
/// Holds a **STRONG** reference to `owner` — a weak ref would silently
/// drop bytes if the caller releases their strong ref while the channel
/// is alive. The retain cycle (PaneControlChannelClient → child pipeline →
/// InboundResponseRelay → owner) is bounded: NIO removes all handlers
/// from the pipeline when the child channel closes, breaking the cycle
/// at that point. This matches the R4 `TerminalSessionClient.InboundRelay`
/// pattern.
private final class InboundResponseRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let owner: PaneControlChannelClient

    init(owner: PaneControlChannelClient) { self.owner = owner }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        owner.deliverInbound(Data(buf.readableBytesView))
    }
}
