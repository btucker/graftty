import Foundation
import GrafttyProtocol
import NIOCore
import NIOSSH

/// Client for the authenticated worktree-management subsystem.
///
/// A response timeout or failed write closes the channel: the wire has no
/// request IDs, so a late reply must never answer a later request.
public final class WorktreeManagementChannelClient: @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case openFailed(any Error)
        case channelClosed
        case subsystemRejected
        case busy
        case timedOut
    }

    private let rpc: SubsystemRPCChannel<WorktreeManagementRequest, WorktreeManagementResponse>

    public convenience init(
        parentChannel: Channel,
        parentHandler: NIOSSHHandler,
        subsystemReplyTimeout: TimeAmount = .seconds(30),
        responseTimeout: TimeAmount = .seconds(30)
    ) {
        self.init(
            parentChannel: parentChannel,
            parentHandler: parentHandler,
            subsystemReplyTimeout: .nanoseconds(subsystemReplyTimeout.nanoseconds),
            responseDeadline: .after(.nanoseconds(responseTimeout.nanoseconds))
        )
    }

    init(
        parentChannel: Channel,
        parentHandler: NIOSSHHandler,
        subsystemReplyTimeout: Duration,
        responseDeadline: ReplyDeadline
    ) {
        rpc = SubsystemRPCChannel(
            parentChannel: parentChannel,
            parentHandler: parentHandler,
            subsystem: SSHChannelTypeNames.worktreeManagement,
            reply: .acknowledged(timeout: subsystemReplyTimeout),
            policy: .init(
                deadline: responseDeadline,
                closesOnDesync: true,
                strictFrames: false,
                closesOnCancellation: false
            ),
            errors: SubsystemErrors(
                closed: ClientError.channelClosed,
                rejected: ClientError.subsystemRejected,
                timedOut: ClientError.timedOut
            ),
            busy: ClientError.busy,
            decode: { try JSONDecoder.shared.decode(WorktreeManagementResponse.self, from: $0) }
        )
    }

    public func open() async throws {
        do {
            try await rpc.open()
        } catch {
            throw ClientError.openFailed(error)
        }
    }

    public func send(
        _ request: WorktreeManagementRequest
    ) async throws -> WorktreeManagementResponse {
        try await rpc.send(request)
    }

    public func close() {
        rpc.close()
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
