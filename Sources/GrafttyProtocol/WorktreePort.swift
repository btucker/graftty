import Foundation

/// A TCP listener belonging to a worktree's processes.
/// @spec PORTS-5.2: When a worktree snapshot includes listening ports, the application shall preserve their process names, bind scopes, and listener addresses on the wire and treat absent ports from older hosts as an empty list.
public struct WorktreePort: Codable, Sendable, Hashable, Identifiable {
    public enum Scope: String, Codable, Sendable, Hashable { case loopback, lan }
    public let port: UInt16
    public let scope: Scope
    public let processName: String
    public let host: String
    public var id: UInt16 { port }
    public var url: URL? {
        let authority = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(authority):\(port)/")
    }

    public init(port: UInt16, scope: Scope, processName: String, host: String = "localhost") {
        self.port = port
        self.scope = scope
        self.processName = processName
        self.host = host
    }
}
