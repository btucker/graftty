import Foundation
import GrafttyProtocol
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// Client-side endpoint for the `pane-control@graftty.dev` SSH subsystem.
///
/// `open()` resolves once the subsystem request (`wantReply: true`) is
/// written; a host refusal surfaces as the channel closing, which fails
/// the next RPC with `.channelClosed`.
///
/// Single in-flight RPC per channel. Production wraps this in
/// `PaneControlClient`, which queues mutations. A failed exchange retires
/// its channel; the next mutation opens a fresh child on the same SSH parent.
/// The failed mutation is never replayed because the host may have applied it.
public final class PaneControlChannelClient: @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case openFailed(any Error)
        case channelClosed
        /// A `send(_:)` call was issued while another RPC was already
        /// in flight. Returned as a soft error rather than a precondition
        /// failure so a concurrent caller cannot crash the client.
        case busy
        /// The RPC missed its deadline. Its channel is invalidated before
        /// the caller resumes so a late reply cannot answer another RPC.
        case timedOut
    }

    /// Default per-RPC deadline. Without one a hung host mutator would park
    /// the caller forever and every later RPC would trip `.busy`.
    public static let rpcDeadline: Duration = .seconds(30)

    private typealias RPC = SubsystemRPCChannel<PaneControlRequest, PaneControlResponse>
    private let makeRPC: () -> RPC
    private let lock = NIOLock()
    // Protected by lock, including the busy guard across a recovery open.
    private var rpc: RPC
    private var needsOpen = false
    private var hasOpened = false
    private var isSending = false
    private var isClosed = false

    public convenience init(
        parentChannel: Channel,
        parentHandler: NIOSSHHandler,
        rpcDeadline: Duration = PaneControlChannelClient.rpcDeadline
    ) {
        self.init(
            parentChannel: parentChannel,
            parentHandler: parentHandler,
            responseDeadline: .after(rpcDeadline)
        )
    }

    init(parentChannel: Channel, parentHandler: NIOSSHHandler, responseDeadline: ReplyDeadline) {
        let makeRPC = {
            RPC(
                parentChannel: parentChannel,
                parentHandler: parentHandler,
                subsystem: SSHChannelTypeNames.paneControl,
                reply: .written(wantReply: true),
                policy: .init(
                    deadline: responseDeadline,
                    closesOnDesync: true,
                    strictFrames: false,
                    closesOnCancellation: false
                ),
                errors: SubsystemErrors(
                    closed: ClientError.channelClosed,
                    rejected: ClientError.channelClosed,
                    timedOut: ClientError.timedOut
                ),
                busy: ClientError.busy,
                decode: { bytes in
                    do {
                        return try JSONDecoder.shared.decode(PaneControlResponse.self, from: bytes)
                    } catch {
                        return .error(code: "malformed-response", message: String(describing: error))
                    }
                }
            )
        }
        self.makeRPC = makeRPC
        rpc = makeRPC()
    }

    public func open() async throws {
        let current = try lock.withLock {
            guard !hasOpened, !isClosed else {
                throw ClientError.openFailed(ClientError.channelClosed)
            }
            return rpc
        }
        try await open(current)
        try lock.withLock {
            guard !isClosed else { throw ClientError.channelClosed }
            hasOpened = true
        }
    }

    private func open(_ current: RPC) async throws {
        do {
            try await current.open()
        } catch {
            throw ClientError.openFailed(error)
        }
    }

    public func send(_ request: PaneControlRequest) async throws -> PaneControlResponse {
        let (current, reopen) = try lock.withLock {
            guard hasOpened, !isClosed else { throw ClientError.channelClosed }
            guard !isSending else { throw ClientError.busy }
            isSending = true
            return (rpc, needsOpen)
        }
        defer { lock.withLock { isSending = false } }
        do {
            if reopen {
                try await open(current)
                lock.withLock { needsOpen = false }
            }
            return try await current.send(request)
        } catch {
            // Timeout and write failure already invalidate the channel inside
            // SSHReplyWaiter before resuming us. Retire all failed exchanges
            // here as well, and prepare recovery before returning to the queue.
            current.close()
            lock.withLock {
                guard !isClosed else { return }
                rpc = makeRPC()
                needsOpen = true
            }
            throw error
        }
    }

    public func close() {
        let current = lock.withLock {
            isClosed = true
            return rpc
        }
        current.close()
    }
}
