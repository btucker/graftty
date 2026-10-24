import Foundation
import GrafttyProtocol

/// Generates native MCP entries for a fresh managed profile. Callers stage the
/// complete result; this does not merge or overwrite a user's existing settings.
public enum MCPBridgeFiles {
    public static func generate(_ configurations: [MCPBridgeConfiguration], executable: String,
                                configurationDirectory: String, socketPath: String) throws -> [String: Data] {
        guard executable.hasPrefix("/"), configurationDirectory.hasPrefix("/"), socketPath.hasPrefix("/"),
              configurations.count <= 32,
              Set(configurations.map { Data($0.scope.serverID.utf8) }).count == configurations.count,
              Set(configurations.map(\.scope.grantID)).count == configurations.count else { throw MCPProxyError.invalidRequest }
        var files: [String: Data] = [:]
        var claude: [String: Any] = [:]
        var codex = ""
        for configuration in configurations.sorted(by: { $0.scope.serverID < $1.scope.serverID }) {
            let name = configuration.scope.serverID
            guard !name.isEmpty, name.utf8.count <= 128,
                  name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }) else {
                throw MCPProxyError.invalidRequest
            }
            let filename = configuration.scope.grantID.uuidString.lowercased() + ".json"
            files[filename] = try JSONEncoder().encode(configuration)
            let arguments = ["remote", "mcp", "bridge", "--config", configurationDirectory + "/" + filename]
            claude[name] = ["type": "stdio", "command": executable, "args": arguments, "env": ["GRAFTTY_SOCK": socketPath]]
            codex += "[mcp_servers.\(name)]\ncommand = \(try quote(executable))\nargs = \(try quote(arguments))\n"
            codex += "[mcp_servers.\(name).env]\nGRAFTTY_SOCK = \(try quote(socketPath))\n\n"
        }
        files["claude-mcp.json"] = try JSONSerialization.data(withJSONObject: ["mcpServers": claude], options: [.sortedKeys, .prettyPrinted])
        files["codex-mcp.toml"] = Data(codex.utf8)
        return files
    }
    private static func quote<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
