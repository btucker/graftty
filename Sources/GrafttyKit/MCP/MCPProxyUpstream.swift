import Foundation
import GrafttyProtocol
import MCP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Uses upstream transports unchanged. Only parent-owned definitions reach this
/// factory. Diagnostics and credential-bearing configuration never leave it.
public enum MCPProxyUpstream {
    public static func open(_ server: MCPProxyPolicy.Server, processScope: DuplexSubprocessScope? = nil) async throws -> MCPProxyEndpoint {
        switch server {
        case .stdio(let executable, let arguments, let keys):
            guard executable.hasPrefix("/"), !executable.contains("\0"), arguments.count <= 256 else {
                throw MCPProxyError.unavailable
            }
            let inherited = CLIRunner.enrichedEnvironment()
            var environment: [String: String] = [:]
            for key in Set(["HOME", "PATH", "TMPDIR", "LANG"] + keys) { environment[key] = inherited[key] }
            let create = { try DuplexSubprocess(executable: URL(fileURLWithPath: executable), arguments: arguments, environment: environment) }
            let process: DuplexSubprocess
            if let processScope { process = try processScope.launch(create) }
            else { process = try create() }
            let transport = StdioTransport(input: .init(rawValue: process.output.fileDescriptor),
                                           output: .init(rawValue: process.input.fileDescriptor))
            return MCPProxyEndpoint(transport: transport, stop: { await process.stop() })
        case .http:
            // The pinned SDK does not expose its HTTP URLSession injection.
            // Enable this only with tested redirect and parent auth integration.
            throw MCPProxyError.unavailable
        }
    }
}
