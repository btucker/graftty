import Foundation

/// @spec PORTS-5.21: When pane port metadata is sent, the application shall preserve session-scoped bindings and safe loopback targets while decoding older snapshots without port metadata.
public struct PortBinding: Hashable, Sendable, Codable {
    public let port: UInt16
    public let scope: BindScope
    public let processName: String
    public let pid: Int32
    /// Exact listener destination used by the worktree browser, including LAN interfaces.
    public let host: String
    /// A host-local dial target for this listener; nil means no known loopback route.
    public let targetHost: String?

    public init(port: UInt16, scope: BindScope, processName: String, pid: Int32, host: String? = nil, targetHost: String? = nil) {
        self.port = port
        self.scope = scope
        self.processName = processName
        self.pid = pid
        self.host = host ?? targetHost ?? "localhost"
        self.targetHost = targetHost
    }

    private enum CodingKeys: String, CodingKey {
        case port, scope, processName, pid, host, targetHost
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(port: try values.decode(UInt16.self, forKey: .port),
                  scope: try values.decode(BindScope.self, forKey: .scope),
                  processName: try values.decode(String.self, forKey: .processName),
                  pid: try values.decode(Int32.self, forKey: .pid),
                  host: try values.decodeIfPresent(String.self, forKey: .host),
                  targetHost: try values.decodeIfPresent(String.self, forKey: .targetHost))
    }
}

public enum BindScope: String, Sendable, Hashable, Codable {
    case loopback
    case lan
}
