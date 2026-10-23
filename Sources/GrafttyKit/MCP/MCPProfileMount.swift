import Foundation
import GrafttyProtocol

public struct MCPProfileMount: Sendable {
    public let directory: String
    public let runtime: String
    public let configurations: [MCPBridgeConfiguration]
    public static let containerSocket = "/run/graftty-mcp/bridge.sock"
    public static let containerExecutable = "/opt/graftty-mcp/bin/graftty"
    public var mountArguments: [String] {
        ["--mount", "type=bind,source=\(directory),target=/run/graftty-mcp,readonly",
         "--mount", "type=bind,source=\(runtime),target=/opt/graftty-mcp,readonly"]
    }
    public init(directory: String, runtime: String, configurations: [MCPBridgeConfiguration]) {
        self.directory = directory; self.runtime = runtime; self.configurations = configurations
    }
    public static func validate(_ scopes: [MCPProxyScope], worktree: String) throws {
        guard !scopes.isEmpty, scopes.count <= 32, Set(scopes.map(\.grantID)).count == scopes.count,
              Set(scopes.map(\.serverID)).count == scopes.count,
              Set(scopes.map(\.repositoryID)).count == 1, Set(scopes.map(\.generation)).count == 1,
              scopes.allSatisfy({ $0.generation > 0 && $0.worktreePath.utf8.elementsEqual(worktree.utf8) }) else {
            throw HostRuntimeError.invalid("MCP grants must select unique servers for this worktree and assignment")
        }
    }
    /// Fresh profiles only. No host-side write follows a container-controlled
    /// path; commands execute as the verified container remote user.
    public func installationScript(home: String) throws -> String {
        let quote = WorktreeAgentLaunchCommand.shellLiteral
        let root = home + "/.graftty-mcp"
        let files = try MCPBridgeFiles.generate(configurations, executable: Self.containerExecutable,
            configurationDirectory: root, socketPath: Self.containerSocket)
        var lines = ["set -eu", "umask 077", "mkdir " + quote(root),
                     "mkdir -p " + quote(home + "/.codex") + " " + quote(home + "/.claude")]
        for (name, bytes) in files.sorted(by: { $0.key < $1.key }) {
            let target = quote(root + "/" + name)
            lines.append("(set -C; : > " + target + ")")
            let encoded = Array(bytes.base64EncodedString().utf8)
            for offset in stride(from: 0, to: encoded.count, by: 24_000) {
                let part = String(decoding: encoded[offset..<min(offset + 24_000, encoded.count)], as: UTF8.self)
                lines.append("printf '%s' " + quote(part) + " | base64 -d >> " + target)
            }
        }
        lines.append("(set -C; cat " + quote(root + "/codex-mcp.toml") + " > " + quote(home + "/.codex/config.toml") + ")")
        lines.append("(set -C; cat " + quote(root + "/claude-mcp.json") + " > " + quote(home + "/.claude/.claude.json") + ")")
        return lines.joined(separator: "\n")
    }
}
