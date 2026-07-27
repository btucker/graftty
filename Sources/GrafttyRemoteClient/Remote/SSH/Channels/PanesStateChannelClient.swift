import Foundation
import GrafttyProtocol
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH

/// Client-side endpoint for the `panes-state@graftty.dev` SSH channel.
///
/// Opens a new SSH child channel of type `.session` via the parent
/// `NIOSSHHandler`, sends a `SubsystemRequest` naming
/// `SSHChannelTypeNames.panesState` to identify the channel purpose, then
/// installs length-prefixed framing + an inbound relay and yields decoded
/// `PanesStateMessage` events via the supplied callback.
///
/// Note: swift-nio-ssh 0.13 exposes only `.session`, `.directTCPIP`, and
/// `.forwardedTCPIP` on `SSHChannelType`. Custom channel names per RFC 4254
/// §5.1 are therefore conveyed via a `subsystem` channel request immediately
/// after the channel opens — the same mechanism used by SFTP. The server-side
/// `inboundChildChannelInitializer` is expected to inspect the subsystem name
/// and route accordingly.
public final class PanesStateChannelClient: @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case openFailed(any Error)
        case channelClosed
    }

    public typealias OnSnapshot = @Sendable ([WorktreePanes]) async -> Void
    public typealias OnClosed = @Sendable (String) async -> Void

    private let parentChannel: Channel
    private let parentHandler: NIOSSHHandler
    private let subsystemName: String

    private let lock = NIOLock()
    /// Callbacks are mutable so the construction site can build the
    /// client with placeholders, hand it to its owning store, then
    /// backfill the closures pointing at the store. Production wiring
    /// (`buildPaneEnvironment`) uses that flow to break the
    /// store↔driver chicken-and-egg without a placeholder driver swap.
    private var onSnapshot: OnSnapshot
    private var onClosed: OnClosed
    private var childChannel: Channel?
    private var closed = false
    private var drainTask: Task<Void, Never>?

    /// Serial inbound queue. `deliverInbound` yields raw frame bytes onto
    /// this stream; a single drain Task spawned in `open()` consumes them
    /// in order and dispatches to `onSnapshot`. A per-frame `Task { ... }`
    /// would NOT preserve wire order — Tasks awaiting an actor enqueue
    /// when their body awaits, not when they're spawned, so two snapshots
    /// arriving back-to-back could be applied to `WorktreePanesStore`
    /// out of order, leaving stale state.
    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let inboundStream: AsyncStream<Data>

    public init(
        parentChannel: Channel,
        parentHandler: NIOSSHHandler,
        subsystemName: String = SSHChannelTypeNames.panesState,
        onSnapshot: @escaping OnSnapshot,
        onClosed: @escaping OnClosed
    ) {
        self.parentChannel = parentChannel
        self.parentHandler = parentHandler
        self.subsystemName = subsystemName
        self.onSnapshot = onSnapshot
        self.onClosed = onClosed
        var cont: AsyncStream<Data>.Continuation!
        self.inboundStream = AsyncStream { c in cont = c }
        self.inboundContinuation = cont
    }

    /// Overwrites the snapshot + close callbacks installed at init.
    /// Lets `buildPaneEnvironment` construct the client first, hand it
    /// to its `WorktreePanesStore`, then point the callbacks at the
    /// store — avoiding the chicken-and-egg "store needs the client at
    /// init, client needs the store in its callbacks" cycle.
    public func setCallbacks(
        onSnapshot: @escaping OnSnapshot,
        onClosed: @escaping OnClosed
    ) {
        lock.withLock {
            self.onSnapshot = onSnapshot
            self.onClosed = onClosed
        }
    }

    /// Opens the SSH child channel. Resolves when the subsystem request has
    /// been written to the wire (wantReply: false — no server acknowledgement).
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
                    try child.pipeline.syncOperations.addHandler(
                        InboundSnapshotRelay(owner: self)
                    )
                    return child.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return child.eventLoop.makeFailedFuture(error)
                }
            }
            lock.withLock { self.childChannel = child }
            // Register the close handler IMMEDIATELY — before the subsystem
            // request — so that a partial-open failure still propagates
            // `onClosed` to the store. Otherwise the store's
            // `connectionState` would stay `.subscribed` indefinitely on
            // any post-open failure path.
            child.closeFuture.whenComplete { [weak self] _ in
                self?.handleChildClose()
            }
            // Spawn the single serial drain task that dispatches inbound
            // snapshots in wire order. See `inboundStream` for rationale.
            let drain = Task { [inboundStream, weak self] in
                for await bytes in inboundStream {
                    guard let self else { return }
                    // Snapshot the closure under the lock so a concurrent
                    // setCallbacks(...) doesn't race with the read.
                    let onSnapshot = self.lock.withLock { self.onSnapshot }
                    guard
                        let message = try? JSONDecoder().decode(PanesStateMessage.self, from: bytes)
                    else { continue }
                    switch message {
                    case .snapshot(let worktrees):
                        await onSnapshot(worktrees)
                    }
                }
            }
            lock.withLock { self.drainTask = drain }
            // Send the subsystem request that identifies this session as a
            // panes-state channel. wantReply: false — the server is expected
            // to accept all subsystem requests for known names and we don't
            // need to sequence on the reply before receiving pushes.
            let subsystem = SSHChannelRequestEvent.SubsystemRequest(
                subsystem: subsystemName,
                wantReply: false
            )
            try await child.triggerUserOutboundEvent(subsystem).get()
        } catch {
            // Defense-in-depth: if the open failed after we stashed
            // childChannel, make sure the half-open channel is torn down
            // and the drain task is finished. `handleChildClose` (via the
            // already-registered closeFuture handler) will also fire and
            // finish the continuation, but we belt-and-suspenders it here
            // so a synchronous error path still cleans up.
            let child = lock.withLock { childChannel }
            child?.close(promise: nil)
            throw ClientError.openFailed(error)
        }
    }

    /// Closes the SSH child channel.
    public func close() {
        let child = lock.withLock { () -> Channel? in
            closed = true
            return childChannel
        }
        inboundContinuation.finish()
        child?.close(promise: nil)
    }

    // MARK: - Inbound

    fileprivate func deliverInbound(_ bytes: Data) {
        inboundContinuation.yield(bytes)
    }

    private func handleChildClose() {
        let onClosed = lock.withLock { self.onClosed }
        // Finish the inbound stream so the drain task exits cleanly.
        inboundContinuation.finish()
        Task { await onClosed("channel-closed") }
    }
}

/// Inbound relay installed on the SSH child channel. Forwards inbound
/// `ByteBuffer` frames to the owning `PanesStateChannelClient`.
///
/// Holds a **STRONG** reference to `owner` — a weak ref would silently
/// drop bytes if the caller releases their strong ref while the channel
/// is alive. The retain cycle (PanesStateChannelClient → child pipeline →
/// InboundSnapshotRelay → owner) is bounded: NIO removes all handlers
/// from the pipeline when the child channel closes, breaking the cycle
/// at that point. This matches the R4 `TerminalSessionClient.InboundRelay`
/// pattern.
private final class InboundSnapshotRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let owner: PanesStateChannelClient

    init(owner: PanesStateChannelClient) {
        self.owner = owner
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        owner.deliverInbound(Data(buf.readableBytesView))
    }
}
