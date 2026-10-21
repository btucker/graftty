import Foundation
import GrafttyTunnel
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// Error values a subsystem client surfaces for each shared failure, so
/// every client keeps its own public `ClientError` cases.
struct SubsystemErrors: Sendable {
    /// The channel is not open, or closed underneath the caller.
    var closed: any Error
    /// The peer refused the subsystem (ChannelFailure).
    var rejected: any Error
    /// The subsystem reply or an RPC response missed its deadline.
    var timedOut: any Error
}

/// Inbound tail of a framed subsystem pipeline: hands each decoded frame to
/// `onFrame` on the child's event loop, in wire order.
///
/// `onFrame` may retain the channel's owner strongly — a weak owner would
/// silently drop frames if the caller released it while the channel is
/// alive. NIO removes the pipeline's handlers when the child closes, which
/// bounds that retain cycle.
final class FrameRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let onFrame: @Sendable (Data) -> Void
    private let onError: (@Sendable (any Error) -> Void)?

    /// With an `onError`, a pipeline error is reported there and closes the
    /// channel; without one it continues down the pipeline.
    init(
        onFrame: @escaping @Sendable (Data) -> Void,
        onError: (@Sendable (any Error) -> Void)? = nil
    ) {
        self.onFrame = onFrame
        self.onError = onError
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        onFrame(Data(unwrapInboundIn(data).readableBytesView))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        guard let onError else {
            context.fireErrorCaught(error)
            return
        }
        onError(error)
        context.close(promise: nil)
    }
}

/// Installs `SSHChannelDataCodec` → length-prefixed decoder → prepender →
/// `relay` (→ `ack`) on a freshly opened subsystem child channel.
func installSubsystemPipeline(
    on child: Channel,
    maximumBufferSize: Int?,
    relay: FrameRelay,
    ack: SubsystemAckRelay?
) throws {
    let pipeline = child.pipeline.syncOperations
    // SSHChannelDataCodec bridges SSHChannelData ↔ ByteBuffer so the
    // downstream framing handlers operate on raw bytes.
    try pipeline.addHandler(SSHChannelDataCodec())
    try pipeline.addHandler(LengthPrefixedFraming.makeFrameDecoder(maximumBufferSize: maximumBufferSize))
    try pipeline.addHandler(LengthPrefixedFraming.makeFramePrepender())
    try pipeline.addHandler(relay)
    if let ack { try pipeline.addHandler(ack) }
}

/// One framed `.session` child channel bound to a Graftty SSH subsystem.
///
/// swift-nio-ssh exposes no custom channel types, so each Graftty channel
/// purpose rides a `.session` channel named by an RFC 4254 §6.5
/// `subsystem` request — the mechanism SFTP uses. This type owns the open /
/// frame / ack skeleton every subsystem client shares; callers own what the
/// frames mean.
final class SubsystemChannel: @unchecked Sendable {
    enum Reply: Sendable {
        /// Resolve once the subsystem request is written. A peer refusal
        /// then surfaces as the channel closing. `wantReply` still asks the
        /// peer to answer; nothing waits for that answer.
        case written(wantReply: Bool)
        /// Resolve on the peer's ChannelSuccess. ChannelFailure throws
        /// `SubsystemErrors.rejected`; no reply within `timeout` closes the
        /// channel and throws `SubsystemErrors.timedOut`.
        case acknowledged(timeout: Duration)
    }

    private enum State {
        case idle
        case opening
        case open(Channel)
        case closed
    }

    let errors: SubsystemErrors
    private let parentChannel: Channel
    private let parentHandler: NIOSSHHandler
    private let subsystem: String
    private let maximumBufferSize: Int?
    private let reply: Reply
    private let lock = NIOLock()
    private var state: State = .idle
    private var ackWaiter: SSHSubsystemReplyWaiter?

    init(
        parentChannel: Channel,
        parentHandler: NIOSSHHandler,
        subsystem: String,
        maximumBufferSize: Int? = nil,
        reply: Reply,
        errors: SubsystemErrors
    ) {
        self.parentChannel = parentChannel
        self.parentHandler = parentHandler
        self.subsystem = subsystem
        self.maximumBufferSize = maximumBufferSize
        self.reply = reply
        self.errors = errors
    }

    /// The open child channel; `nil` before `open()` and after any close.
    var channel: Channel? {
        lock.withLock {
            if case .open(let child) = state { return child }
            return nil
        }
    }

    /// Opens the child channel and requests the subsystem. A channel opens
    /// at most once: a repeat call throws `SubsystemErrors.closed` and leaves
    /// the first open untouched; any other failure closes the channel.
    ///
    /// `onFrame` receives each inbound frame. `onClose` runs once, after an
    /// opened child channel closes for any reason, including a refusal after
    /// open; it does not run when `close()` wins the race with the open.
    func open(
        onFrame: @escaping @Sendable (Data) -> Void,
        onError: (@Sendable (any Error) -> Void)? = nil,
        onClose: @escaping @Sendable () -> Void
    ) async throws {
        let waiter: SSHSubsystemReplyWaiter?
        if case .acknowledged = reply { waiter = SSHSubsystemReplyWaiter() } else { waiter = nil }
        try lock.withLock {
            guard case .idle = state else { throw errors.closed }
            state = .opening
            ackWaiter = waiter
        }
        do {
            let child = try await openChildChannel(
                parentChannel: parentChannel,
                parentHandler: parentHandler
            ) { [maximumBufferSize, errors] child, _ in
                child.eventLoop.makeCompletedFuture {
                    try installSubsystemPipeline(
                        on: child,
                        maximumBufferSize: maximumBufferSize,
                        relay: FrameRelay(onFrame: onFrame, onError: onError),
                        ack: waiter.map {
                            SubsystemAckRelay(waiter: $0, rejected: errors.rejected, closed: errors.closed)
                        }
                    )
                }
            }
            let accepted = lock.withLock {
                guard case .opening = state else { return false }
                state = .open(child)
                return true
            }
            guard accepted else {
                child.close(promise: nil)
                throw errors.closed
            }
            // Registered before the subsystem request so a refusal after the
            // child opens still reports the close.
            child.closeFuture.whenComplete { [weak self] _ in
                self?.markClosed()
                onClose()
            }
            switch reply {
            case .written(let wantReply):
                try await child.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.SubsystemRequest(subsystem: subsystem, wantReply: wantReply)
                ).get()
            case .acknowledged(let timeout):
                guard let waiter else { preconditionFailure("acknowledged open without a waiter") }
                try await requestSubsystem(
                    subsystem, on: child, waiter: waiter,
                    timeout: timeout, timeoutError: errors.timedOut
                )
            }
        } catch {
            close()
            throw error
        }
    }

    func close() {
        let child = markClosed()
        child?.close(promise: nil)
    }

    /// Moves to `.closed` and fails any pending subsystem reply, returning
    /// the child channel that was open.
    @discardableResult
    private func markClosed() -> Channel? {
        let (child, waiter) = lock.withLock { () -> (Channel?, SSHSubsystemReplyWaiter?) in
            var child: Channel?
            if case .open(let open) = state { child = open }
            state = .closed
            let waiter = ackWaiter
            ackWaiter = nil
            return (child, waiter)
        }
        waiter?.finish(.failure(errors.closed))
        return child
    }
}

/// A `SubsystemChannel` carrying one request/response RPC at a time.
///
/// The wire has no request IDs: frame N answers request N. Response
/// deadlines run on Swift's clock, because the WebRTC transport's
/// `NIOAsyncTestingEventLoop` never advances its scheduled-task clock.
final class SubsystemRPCChannel<Request: Encodable & Sendable, Response: Sendable>: @unchecked Sendable {
    struct Policy: Sendable {
        var deadline: ReplyDeadline
        /// Close the channel when an RPC times out or its write fails, so a
        /// late reply can never pair with a later request. Otherwise the
        /// timed-out caller is failed and the channel stays usable.
        var closesOnDesync: Bool
        /// Close the channel on a malformed or unsolicited response frame,
        /// or a pipeline error. Otherwise an unsolicited frame is dropped
        /// and a malformed one fails only its RPC.
        var strictFrames: Bool
        /// A cancelled caller aborts its RPC and closes the channel.
        /// Otherwise cancellation is ignored and the RPC waits for its reply,
        /// keeping request/response pairing intact.
        var closesOnCancellation: Bool
    }

    private let channel: SubsystemChannel
    private let policy: Policy
    /// Thrown when an RPC is issued while another is still in flight.
    private let busy: any Error
    private let decode: @Sendable (Data) throws -> Response
    private let lock = NIOLock()
    private var pending: SSHReplyWaiter<Response>?

    init(
        parentChannel: Channel,
        parentHandler: NIOSSHHandler,
        subsystem: String,
        maximumBufferSize: Int? = nil,
        reply: SubsystemChannel.Reply,
        policy: Policy,
        errors: SubsystemErrors,
        busy: any Error,
        decode: @escaping @Sendable (Data) throws -> Response
    ) {
        self.channel = SubsystemChannel(
            parentChannel: parentChannel,
            parentHandler: parentHandler,
            subsystem: subsystem,
            maximumBufferSize: maximumBufferSize,
            reply: reply,
            errors: errors
        )
        self.policy = policy
        self.busy = busy
        self.decode = decode
    }

    private var errors: SubsystemErrors { channel.errors }

    func open() async throws {
        let onError: (@Sendable (any Error) -> Void)?
        if policy.strictFrames {
            onError = { [weak self] _ in self?.close() }
        } else {
            onError = nil
        }
        try await channel.open(
            onFrame: { [self] bytes in self.deliver(bytes) },
            onError: onError,
            onClose: { [weak self] in self?.failPending() }
        )
    }

    func send(_ request: Request) async throws -> Response {
        try await send(encoded: JSONEncoder().encode(request))
    }

    /// Sends an already-encoded request, for callers that bound its size.
    func send(encoded body: Data) async throws -> Response {
        if policy.closesOnCancellation {
            return try await exchange(body)
        }
        // An unstructured task does not inherit the caller's cancellation.
        return try await Task { try await self.exchange(body) }.value
    }

    func close() {
        channel.close()
        failPending()
    }

    private func exchange(_ body: Data) async throws -> Response {
        guard let child = channel.channel else { throw errors.closed }
        let waiter = SSHReplyWaiter<Response>()
        let registered = lock.withLock {
            guard pending == nil else { return false }
            pending = waiter
            return true
        }
        guard registered else { throw busy }
        defer { lock.withLock { if pending === waiter { pending = nil } } }
        let buffer = child.allocator.buffer(bytes: body)
        return try await waiter.wait(
            scheduleTimeout: policy.deadline.schedule,
            timeoutError: errors.timedOut,
            onAbort: { [weak self] in self?.desynchronized() },
            // Reachable only when `closesOnCancellation`: `send` shields
            // other callers' RPCs from cancellation.
            onCancel: { [weak self] in self?.close() },
            start: { [weak self] in
                let owner = self
                child.writeAndFlush(buffer).whenFailure { error in
                    waiter.finish(.failure(error), beforeResuming: { owner?.desynchronized() })
                }
            }
        )
    }

    private func deliver(_ bytes: Data) {
        let waiter = lock.withLock { () -> SSHReplyWaiter<Response>? in
            defer { pending = nil }
            return pending
        }
        guard let waiter else {
            if policy.strictFrames { close() }
            return
        }
        do {
            waiter.finish(.success(try decode(bytes)))
        } catch {
            waiter.finish(.failure(error), beforeResuming: { [weak self] in
                if self?.policy.strictFrames == true { self?.close() }
            })
        }
    }

    private func desynchronized() {
        if policy.closesOnDesync { close() }
    }

    private func failPending() {
        let waiter = lock.withLock { () -> SSHReplyWaiter<Response>? in
            defer { pending = nil }
            return pending
        }
        waiter?.finish(.failure(errors.closed))
    }
}
