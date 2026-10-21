import Foundation
import GrafttyProtocol
import NIOCore
import NIOSSH

/// Client-side endpoint for the `pane-control@graftty.dev` SSH subsystem.
///
/// `open()` resolves once the subsystem request (`wantReply: true`) is
/// written; a host refusal surfaces as the channel closing, which fails
/// the next RPC with `.channelClosed`.
///
/// One channel per `RemoteHostConnection`. Single in-flight RPC per
/// channel — clients serialise their own RPCs (parent design §8.1).
/// Production wraps this in `PaneControlClient`, which queues them.
public final class PaneControlChannelClient: @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case openFailed(any Error)
        case channelClosed
        /// A `send(_:)` call was issued while another RPC was already
        /// in flight. Returned as a soft error rather than a precondition
        /// failure so a concurrent caller cannot crash the client.
        case busy
        /// The RPC didn't receive a response within its deadline. The host
        /// is presumed wedged (mutator deadlock, etc.); the channel is
        /// left open so subsequent RPCs can attempt to make progress.
        case timedOut
    }

    /// Default per-RPC deadline. Without one a hung host mutator would park
    /// the caller forever and every later RPC would trip `.busy`.
    public static let rpcDeadline: Duration = .seconds(30)

    private let rpc: SubsystemRPCChannel<PaneControlRequest, PaneControlResponse>

    public init(
        parentChannel: Channel,
        parentHandler: NIOSSHHandler,
        rpcDeadline: Duration = PaneControlChannelClient.rpcDeadline
    ) {
        rpc = SubsystemRPCChannel(
            parentChannel: parentChannel,
            parentHandler: parentHandler,
            subsystem: SSHChannelTypeNames.paneControl,
            reply: .written(wantReply: true),
            policy: .init(
                timeout: rpcDeadline,
                closesOnDesync: false,
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
                    return try JSONDecoder().decode(PaneControlResponse.self, from: bytes)
                } catch {
                    return .error(code: "malformed-response", message: String(describing: error))
                }
            }
        )
    }

    public func open() async throws {
        do {
            try await rpc.open()
        } catch {
            throw ClientError.openFailed(error)
        }
    }

    public func send(_ request: PaneControlRequest) async throws -> PaneControlResponse {
        try await rpc.send(request)
    }

    public func close() {
        rpc.close()
    }
}
