#if canImport(UIKit)
import GrafttyProtocol
import GrafttyRemoteClient

public typealias RemoteConnectionProvider =
    @Sendable () async -> RemoteHostConnection?

enum RelayedWorktreeManagementClient {
    enum ClientError: Error {
        case pairedConnectionUnavailable
    }

    static func send(
        _ request: WorktreeManagementRequest,
        using provider: RemoteConnectionProvider?
    ) async throws -> WorktreeManagementResponse {
        guard let connection = await provider?() else {
            throw ClientError.pairedConnectionUnavailable
        }
        let client = try await connection.openWorktreeManagementChannel()
        do {
            let response = try await client.send(request)
            client.close()
            return response
        } catch {
            client.close()
            throw error
        }
    }
}
#endif
