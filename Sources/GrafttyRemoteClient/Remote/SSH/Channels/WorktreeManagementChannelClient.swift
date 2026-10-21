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

    public init(
        parentChannel: Channel,
        parentHandler: NIOSSHHandler,
        subsystemReplyTimeout: TimeAmount = .seconds(30),
        responseTimeout: TimeAmount = .seconds(30)
    ) {
        rpc = SubsystemRPCChannel(
            parentChannel: parentChannel,
            parentHandler: parentHandler,
            subsystem: SSHChannelTypeNames.worktreeManagement,
            reply: .acknowledged(timeout: .nanoseconds(subsystemReplyTimeout.nanoseconds)),
            policy: .init(
                timeout: .nanoseconds(responseTimeout.nanoseconds),
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
            decode: { try JSONDecoder().decode(WorktreeManagementResponse.self, from: $0) }
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

/// Queues worktree-management RPCs in order on one channel driver.
public final class WorktreeManagementClient: Sendable {
    private let rpc: SerialRPCClient<WorktreeManagementRequest, WorktreeManagementResponse>

    public init(driver: any WorktreeManagementChannelDriver) {
        rpc = SerialRPCClient(
            policy: .init(
                closedError: WorktreeManagementChannelClient.ClientError.channelClosed,
                queueLimit: nil,
                closesOnCallerCancellation: false
            ),
            open: { try await driver.open() },
            send: { try await driver.send($0) },
            close: { driver.close() }
        )
    }

    public func open() async throws {
        try await rpc.open()
    }

    public func send(
        _ request: WorktreeManagementRequest
    ) async throws -> WorktreeManagementResponse {
        try await rpc.send(request)
    }

    public func close() async {
        await rpc.close()
    }
}
