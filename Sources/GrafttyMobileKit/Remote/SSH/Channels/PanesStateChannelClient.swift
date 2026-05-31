#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH

/// Mobile-side client for the `panes-state@graftty.dev` SSH channel.
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
    private let onSnapshot: OnSnapshot
    private let onClosed: OnClosed

    private let lock = NIOLock()
    private var childChannel: Channel?
    private var closed = false

    public init(
        parentChannel: Channel,
        parentHandler: NIOSSHHandler,
        onSnapshot: @escaping OnSnapshot,
        onClosed: @escaping OnClosed
    ) {
        self.parentChannel = parentChannel
        self.parentHandler = parentHandler
        self.onSnapshot = onSnapshot
        self.onClosed = onClosed
    }

    /// Opens the SSH child channel. Resolves when the subsystem request has
    /// been written to the wire (wantReply: false — no server acknowledgement).
    public func open() async throws {
        let promise = parentChannel.eventLoop.makePromise(of: Channel.self)
        parentHandler.createChannel(promise, channelType: .session) { [weak self] child, _ in
            guard let self else {
                return child.eventLoop.makeFailedFuture(ClientError.channelClosed)
            }
            do {
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
        do {
            let child = try await promise.futureResult.get()
            // Send the subsystem request that identifies this session as a
            // panes-state channel. wantReply: false — the server is expected
            // to accept all subsystem requests for known names and we don't
            // need to sequence on the reply before receiving pushes.
            let subsystem = SSHChannelRequestEvent.SubsystemRequest(
                subsystem: SSHChannelTypeNames.panesState,
                wantReply: false
            )
            lock.withLock { self.childChannel = child }
            try await child.triggerUserOutboundEvent(subsystem).get()
            child.closeFuture.whenComplete { [weak self] _ in
                self?.handleChildClose()
            }
        } catch {
            throw ClientError.openFailed(error)
        }
    }

    /// Closes the SSH child channel.
    public func close() {
        let child = lock.withLock { () -> Channel? in
            closed = true
            return childChannel
        }
        child?.close(promise: nil)
    }

    // MARK: - Inbound

    fileprivate func deliverInbound(_ bytes: Data) {
        let onSnapshot = self.onSnapshot
        Task {
            guard
                let message = try? JSONDecoder().decode(PanesStateMessage.self, from: bytes)
            else { return }
            switch message {
            case .snapshot(let worktrees):
                await onSnapshot(worktrees)
            }
        }
    }

    private func handleChildClose() {
        let onClosed = self.onClosed
        Task { await onClosed("channel-closed") }
    }
}

private final class InboundSnapshotRelay: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    weak var owner: PanesStateChannelClient?

    init(owner: PanesStateChannelClient) {
        self.owner = owner
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        owner?.deliverInbound(Data(buf.readableBytesView))
    }
}
#endif
