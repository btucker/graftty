import Foundation
import GrafttyProtocol

/// Parent-local definitions. Never encode this policy into worker configuration.
public struct MCPProxyPolicy: Codable, Sendable {
    public enum Server: Codable, Sendable, Equatable {
        case stdio(executable: String, arguments: [String], environmentKeys: [String])
        case http(url: URL, bearerTokenEnvironment: String?)
    }
    public struct Grant: Codable, Sendable {
        public var scope: MCPProxyScope
        public var host: RemoteMacConnectionSummary.ID
        public var expiresAt: Date
        public var revoked: Bool
        public init(scope: MCPProxyScope, host: RemoteMacConnectionSummary.ID, expiresAt: Date, revoked: Bool = false) {
            self.scope = scope; self.host = host; self.expiresAt = expiresAt; self.revoked = revoked
        }
    }
    public var servers: [String: Server]
    public var grants: [Grant]
    public init(servers: [String: Server], grants: [Grant]) { self.servers = servers; self.grants = grants }

    public static func load(from file: URL) throws -> Self {
        let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
              let size = metadata.fileSize, size <= 1024 * 1024 else { throw MCPProxyError.unauthorized }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    public func authorize(_ scope: MCPProxyScope, peer: RemoteMacConnectionSummary.ID, now: Date = Date()) throws -> Server {
        guard grants.count <= 4096, servers.count <= 256,
              Set(grants.map(\.scope.grantID)).count == grants.count,
              let grant = grants.first(where: { $0.scope.grantID == scope.grantID }), !grant.revoked,
              grant.expiresAt > now, grant.expiresAt.timeIntervalSince1970.isFinite,
              grant.host.fingerprint == peer.fingerprint,
              grant.host.deviceID.value.utf8.elementsEqual(peer.deviceID.value.utf8),
              grant.scope.generation == scope.generation, scope.generation > 0,
              grant.scope.repositoryID == scope.repositoryID,
              grant.scope.worktreePath.utf8.elementsEqual(scope.worktreePath.utf8),
              grant.scope.serverID.utf8.elementsEqual(scope.serverID.utf8),
              let entry = servers.first(where: { $0.key.utf8.elementsEqual(scope.serverID.utf8) }) else {
            throw MCPProxyError.unauthorized
        }
        return entry.value
    }
}
