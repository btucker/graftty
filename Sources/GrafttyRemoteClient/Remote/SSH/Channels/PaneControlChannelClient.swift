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

    /// The client's whole lifecycle. Each case owns the channel it may use, so
    /// a channel can never be sent on before it opens or after it is retired.
    private enum Phase {
        /// Created; `open()` has not been called.
        case unopened(RPC)
        /// The first `open()` is in flight.
        case opening(RPC)
        /// Open and idle.
        case ready(RPC)
        /// A failed exchange retired its channel; this replacement opens
        /// at the start of the next `send(_:)`.
        case needsReopen(RPC)
        /// One exchange is in flight, including any recovery open before it.
        case sending(RPC)
        /// Closed by the caller, or the first open failed. Terminal.
        case closed
    }
    // Protected by lock.
    private var phase: Phase

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
        phase = .unopened(makeRPC())
    }

    public func open() async throws {
        let current = try lock.withLock {
            guard case .unopened(let rpc) = phase else {
                throw ClientError.openFailed(ClientError.channelClosed)
            }
            phase = .opening(rpc)
            return rpc
        }
        do {
            try await open(current)
        } catch {
            // A subsystem channel opens at most once, so this client cannot recover.
            lock.withLock { if case .opening = phase { phase = .closed } }
            throw error
        }
        try lock.withLock {
            guard case .opening = phase else { throw ClientError.channelClosed }
            phase = .ready(current)
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
            switch phase {
            case .ready(let rpc):
                phase = .sending(rpc)
                return (rpc, false)
            case .needsReopen(let rpc):
                phase = .sending(rpc)
                return (rpc, true)
            case .sending:
                throw ClientError.busy
            case .unopened, .opening, .closed:
                throw ClientError.channelClosed
            }
        }
        do {
            if reopen { try await open(current) }
            let response = try await current.send(request)
            lock.withLock { if case .sending = phase { phase = .ready(current) } }
            return response
        } catch {
            // Timeout and write failure already invalidate the channel inside
            // SSHReplyWaiter before resuming us. Retire all failed exchanges
            // here as well, and prepare recovery before returning to the queue.
            current.close()
            lock.withLock { if case .sending = phase { phase = .needsReopen(makeRPC()) } }
            throw error
        }
    }

    public func close() {
        let current: RPC? = lock.withLock {
            defer { phase = .closed }
            switch phase {
            case .unopened(let rpc), .opening(let rpc), .ready(let rpc), .needsReopen(let rpc), .sending(let rpc):
                return rpc
            case .closed:
                return nil
            }
        }
        current?.close()
    }
}
