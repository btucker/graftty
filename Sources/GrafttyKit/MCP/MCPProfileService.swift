import Foundation
import GrafttyProtocol

/// Owns sockets independently of native agent processes. Restart reconstructs
/// endpoints from the host's retained placement ledger, never profile files.
@MainActor public final class MCPProfileService {
    private struct Endpoint { let socket: SocketServer; let gate: MCPProfileGate; let mount: MCPProfileMount }
    private let directory: URL
    private let runtime: URL
    private let send: @Sendable (MCPBridgeRequest) async -> MCPProxyResponse
    private var endpoints: [UUID: Endpoint] = [:]
    public init(directory: URL, runtime: URL, send: @escaping @Sendable (MCPBridgeRequest) async -> MCPProxyResponse) {
        self.directory = directory; self.runtime = runtime; self.send = send
    }
    public func prepare(operationID: UUID, configurations: [MCPBridgeConfiguration]) throws -> MCPProfileMount {
        guard endpoints[operationID] == nil else { throw HostRuntimeError.busy("MCP endpoint already exists") }
        let runtime = runtime.resolvingSymlinksInPath()
        guard runtime.path.hasPrefix("/"), !runtime.path.contains(","),
              !runtime.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent("bin/graftty").path),
              FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent("libexec/graftty-cli").path) else {
            throw HostRuntimeError.invalid("Container MCP requires the installed Linux Graftty runtime bundle")
        }
        _ = try MCPBridgeFiles.generate(configurations, executable: MCPProfileMount.containerExecutable,
            configurationDirectory: "/profile", socketPath: MCPProfileMount.containerSocket)
        let mount = try DevContainerProfileMount(directory: directory, operationID: operationID)
        defer { mount.removeProbe() }
        let path = mount.directory + "/bridge.sock"
        guard path.utf8.count <= SocketServer.maxPathBytes else { throw HostRuntimeError.invalid("MCP socket path is too long") }
        let gate = MCPProfileGate(configurations: configurations, send: send)
        let socket = SocketServer(socketPath: path)
        socket.onAsyncRequest = { await gate.handle($0) }
        do {
            try socket.start()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch { socket.stop(); throw error }
        let result = MCPProfileMount(directory: mount.directory, runtime: runtime.path, configurations: configurations)
        endpoints[operationID] = Endpoint(socket: socket, gate: gate, mount: result)
        return result
    }
    public func stop(operationID: UUID) async {
        guard let endpoint = endpoints.removeValue(forKey: operationID) else { return }
        endpoint.socket.stop()
        await endpoint.gate.stop()
    }
    public func stop() async { for id in Array(endpoints.keys) { await stop(operationID: id) } }
}
