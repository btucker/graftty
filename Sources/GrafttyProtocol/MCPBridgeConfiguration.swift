import Foundation

/// Safe to stage in a managed profile. Possessing it grants no authority.
public struct MCPBridgeConfiguration: Codable, Sendable {
    public var parent: RemoteMacConnectionSummary.ID
    public var scope: MCPProxyScope
    public init(parent: RemoteMacConnectionSummary.ID, scope: MCPProxyScope) {
        self.parent = parent; self.scope = scope
    }
}
