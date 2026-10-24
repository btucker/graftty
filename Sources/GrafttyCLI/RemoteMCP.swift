import ArgumentParser
import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

struct RemoteMCP: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Use granted MCP servers on the parent without copying credentials",
        subcommands: [Start.self, Stop.self, Status.self, Connect.self, Stage.self, Bridge.self])

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save a parent MCP connection owned by the running Mac app",
            discussion: "Reconnects while the app runs and restores on app launch. Uses a reviewed parent-local policy. Connected means the authenticated transport is ready; tool and model authentication remain separate.")
        @Option(help: "Provider identifier") var provider: String = "aws"
        @Option(help: "Completed provider enrollment UUID") var operationId: String
        @Option(help: "Parent-local JSON MCP policy file") var policy: String
        @Flag(help: "Print connection status as JSON") var json = false
        func validate() throws { _ = try RemoteMCP.operation(operationId) }
        func run() throws {
            let file = URL(fileURLWithPath: policy).standardizedFileURL
            _ = try MCPProxyPolicy.load(from: file)
            try RemoteMCP.request(.start(.init(provider: provider, operationID: RemoteMCP.operation(operationId), policyPath: file.path)), json: json)
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove saved MCP connection intent and close its sessions",
            discussion: "Stops reconnecting immediately. Status may remain stopping while the transport closes.")
        @Option(help: "Provider identifier") var provider: String = "aws"
        @Option(help: "Completed provider enrollment UUID") var operationId: String
        @Flag(help: "Print connection status as JSON") var json = false
        func validate() throws { _ = try RemoteMCP.operation(operationId) }
        func run() throws { try RemoteMCP.request(.stop(provider: provider, operationID: RemoteMCP.operation(operationId)), json: json) }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List app-owned parent MCP connection states")
        @Flag(help: "Print connection status as JSON") var json = false
        func run() throws { try RemoteMCP.request(.list, json: json) }
    }

    private static func operation(_ value: String) throws -> UUID {
        guard let operation = UUID(uuidString: value) else { throw ValidationError("Invalid enrollment UUID") }
        return operation
    }

    private static func request(_ request: MCPConnectionRequest, json: Bool) throws {
        let response = try CLIEnv.sendRequest(.mcpConnection(request))
        guard case .mcpConnections(let statuses) = response else {
            if case .error(let message) = response { throw ValidationError(message) }
            throw ValidationError("Update and start Graftty on the parent Mac.")
        }
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(statuses), as: UTF8.self))
        } else if statuses.isEmpty { print("No app-owned parent MCP connections.") }
        else {
            for status in statuses {
                print("\(status.configuration.provider) \(status.configuration.operationID.uuidString) \(status.state.rawValue)")
            }
        }
    }

    struct Connect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Keep a parent MCP connection to an enrolled worker open",
            discussion: "Run on the parent Mac. The private policy file contains reviewed server definitions and explicit, expiring worker/worktree grants. Policy changes are checked during active sessions. Stdio servers execute on this Mac. Keep this command running while remote agents use its servers.")
        @Option(help: "Provider identifier") var provider: String = "aws"
        @Option(help: "Completed provider enrollment UUID") var operationId: String
        @Option(help: "Parent-local JSON MCP policy file") var policy: String

        func run() async throws {
            guard let operation = UUID(uuidString: operationId) else { throw ValidationError("Invalid enrollment UUID") }
            let file = URL(fileURLWithPath: policy)
            _ = try MCPProxyPolicy.load(from: file)
            let parent: LinuxHostTrustRequest
            switch try CLIEnv.sendRequest(.linuxSetupIdentity) {
            case .linuxSetupIdentity(let identity): parent = identity
            default: throw ValidationError("Update and start Graftty on the parent Mac.")
            }
            guard let key = try ClientIdentityStore(directory: ClientIdentityStore.defaultDirectory).load(),
                  key.publicKey.rawRepresentation.base64EncodedString() == parent.publicKey else {
                throw ValidationError("The saved parent SSH identity is missing or changed.")
            }
            let enrollment = AWSHostEnrollment(peers: TrustedPeerStore(directory: TrustedPeerStore.defaultDirectory))
            let registry = try HostProviderRegistry(providers: [AWSHostProvider(enrollment: enrollment)])
            try await withCLIInterruptCancellation {
                let plan = try await registry.prepareConnection(binding: .init(provider: provider, operationID: operation), parent: parent)
                guard let publicKey = Data(base64Encoded: plan.identity.publicKey) else { throw ValidationError("Invalid enrolled host key") }
                let fingerprint = RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: publicKey))
                let peer = RemoteMacConnectionSummary.ID(deviceID: .init(value: plan.identity.deviceID), fingerprint: fingerprint)
                let connection = DirectSSHHostConnection(clientKey: key, expectedHostFingerprint: fingerprint)
                let broker = MCPProxyBroker(peer: peer, authorize: { scope, identity in
                    try registry.authorize(plan, parent: parent)
                    return try MCPProxyPolicy.load(from: file).authorize(scope, peer: identity)
                })
                var proxy: DuplexSubprocess?
                do {
                    switch plan.transport {
                    case .directSSH(let host, let port): try await connection.connect(host: host, port: port)
                    case .proxy(let command, let arguments):
                        let process = try DuplexSubprocess(command: command, arguments: arguments)
                        proxy = process
                        try await connection.connect(input: process.output, output: process.input)
                    }
                    try registry.authorize(plan, parent: parent)
                    let channel = try await connection.makeMCPControlClient(handler: { await broker.handle($0) }, onClose: { await broker.close() })
                    try await channel.open()
                    guard try await channel.send(MCPProxyControl.ready) == MCPProxyControl.ready else { throw MCPProxyError.unavailable }
                    FileHandle.standardError.write(Data("Parent MCP connection ready. Stdio tools execute on this Mac.\n".utf8))
                    while !Task.isCancelled {
                        guard !(await broker.isClosed) else { throw MCPProxyError.unavailable }
                        try await Task.sleep(for: .seconds(1))
                        try registry.authorize(plan, parent: parent)
                    }
                    channel.close()
                } catch {
                    await broker.close(); await connection.close(); await proxy?.stop()
                    if error is CancellationError { return }
                    // No provider diagnostics, upstream errors or tool payloads.
                    throw ValidationError("Parent MCP connection unavailable. Check enrollment, policy and host readiness.")
                }
                await broker.close(); await connection.close(); await proxy?.stop()
            }
        }
    }

    struct Stage: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Generate native Claude and Codex MCP entries in a new directory")
        @Option(help: "JSON array of MCPBridgeConfiguration grant addresses") var grants: String
        @Option(help: "New output directory; existing directories are rejected") var directory: String
        @Option(help: "Absolute Graftty CLI path inside the worker") var executable: String
        @Option(help: "Absolute private worker Graftty socket path") var socket: String
        @Option(help: "Configuration directory as seen by the agent; defaults to output directory") var agentDirectory: String?
        func run() throws {
            let destination = URL(fileURLWithPath: directory).standardizedFileURL
            let configurations = try JSONDecoder().decode([MCPBridgeConfiguration].self, from: Data(contentsOf: URL(fileURLWithPath: grants)))
            let files = try MCPBridgeFiles.generate(configurations, executable: executable,
                configurationDirectory: agentDirectory ?? destination.path, socketPath: socket)
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".mcp-stage-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: staging) }
            for (name, bytes) in files {
                let file = staging.appendingPathComponent(name)
                try bytes.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            print(destination.path)
        }
    }

    struct Bridge: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a standard MCP stdio bridge for one granted server",
            discussion: "Internal agent entry point. The config contains only the parent identity and grant scope, never upstream commands or credentials. Requires the worker's private Graftty socket.")
        @Option(help: "JSON file containing MCPBridgeConfiguration") var config: String
        func run() async throws {
            let settings = try JSONDecoder().decode(MCPBridgeConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: config)))
            try await withCLIInterruptCancellation {
                try await MCPStdioBridge.run(scope: settings.scope) { request in
                    try await Task.detached {
                        let result = try CLIEnv.sendRequest(.mcpBridge(.init(parent: settings.parent, request: request)))
                        guard case .mcpProxy(let response) = result else { throw MCPProxyError.unavailable }
                        return response
                    }.value
                }
            }
        }
    }
}
