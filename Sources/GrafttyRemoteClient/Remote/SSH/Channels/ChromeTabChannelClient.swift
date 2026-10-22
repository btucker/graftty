import Foundation
import GrafttyProtocol
import NIOCore
import NIOSSH

/// Bounded typed RPCs on the authenticated Chrome subsystem.
///
/// Any desynchronising event — a timeout, a failed write, a malformed or
/// unsolicited response, or a cancelled caller — closes the channel.
public final class ChromeTabChannelClient: @unchecked Sendable {
    public enum ClientError: Error, Sendable { case channelClosed, busy, timedOut, unsupported }

    private let rpc: SubsystemRPCChannel<ChromeTabRequest, ChromeTabResponse>

    public init(parentChannel: Channel, parentHandler: NIOSSHHandler, timeout: Duration = .seconds(30)) {
        rpc = SubsystemRPCChannel(
            parentChannel: parentChannel,
            parentHandler: parentHandler,
            subsystem: SSHChannelTypeNames.chromeTabs,
            maximumBufferSize: ChromeTabRequest.maximumResponseBytes + 4,
            reply: .acknowledged(timeout: timeout),
            policy: .init(
                deadline: .after(timeout),
                closesOnDesync: true,
                strictFrames: true,
                closesOnCancellation: true
            ),
            errors: SubsystemErrors(
                closed: ClientError.channelClosed,
                rejected: ClientError.unsupported,
                timedOut: ClientError.timedOut
            ),
            busy: ClientError.busy,
            decode: { try JSONDecoder.shared.decode(ChromeTabResponse.self, from: $0) }
        )
    }

    public func open() async throws {
        try await rpc.open()
    }

    public func send(_ request: ChromeTabRequest) async throws -> ChromeTabResponse {
        let body = try JSONEncoder.shared.encode(request)
        guard body.count <= ChromeTabRequest.maximumRequestBytes else { throw ClientError.channelClosed }
        return try await rpc.send(encoded: body)
    }

    public func close() {
        rpc.close()
    }
}
