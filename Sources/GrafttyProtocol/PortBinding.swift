import Foundation

/// @spec PORTS-5.1: When pane port metadata is sent, the application shall preserve session-scoped bindings and safe loopback targets while decoding older snapshots without port metadata.
public struct PortBinding: Hashable, Sendable, Codable {
    public let port: UInt16
    public let scope: BindScope
    public let processName: String
    public let pid: Int32
    /// A host-local dial target for this listener; nil means no known loopback route.
    public let targetHost: String?

    public init(port: UInt16, scope: BindScope, processName: String, pid: Int32, targetHost: String? = nil) {
        self.port = port
        self.scope = scope
        self.processName = processName
        self.pid = pid
        self.targetHost = targetHost
    }
}

public enum BindScope: String, Sendable, Hashable, Codable {
    case loopback
    case lan
}
