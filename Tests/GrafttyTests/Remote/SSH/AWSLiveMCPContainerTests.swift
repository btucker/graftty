import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import Testing

extension AWSLiveHostTests {
    /// Requires a disposable registered repository with the native-agent fixture image.
    func exerciseManagedMCP(connection: DirectSSHHostConnection, target: AWSHostEnrollmentTarget, root: URL,
                            worker: RemoteMacConnectionSummary.ID, parent: RemoteMacConnectionSummary.ID,
                            remoteRepository: String) async throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let marker = root.appendingPathComponent("container-mcp-marker")
        let credential = root.appendingPathComponent("container-mcp-credential")
        try Data(("graftty-parent-only-" + UUID().uuidString).utf8).write(to: credential)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)
        let operation = UUID()
        let name = "mcp-" + operation.uuidString.lowercased().prefix(8)
        let scope = MCPProxyScope(grantID: UUID(), generation: 1, repositoryID: UUID(),
            worktreePath: remoteRepository + "/.worktrees/" + name, serverID: "fixture")
        var unselected = scope
        unselected.grantID = UUID(); unselected.serverID = "other"; unselected.worktreePath += "-other"
        let server = MCPProxyPolicy.Server.stdio(executable: "/usr/bin/python3",
            arguments: [repository.appendingPathComponent("scripts/linux/mcp-fixture-server.py").path, marker.path, credential.path], environmentKeys: [])
        let policy = MCPProxyPolicy(servers: ["fixture": server, "other": server], grants: [scope, unselected].map {
            .init(scope: $0, host: worker, expiresAt: Date().addingTimeInterval(240))
        })
        // The parent grants both scopes. Only the local profile boundary can
        // reject using the second scope through the first profile's socket.
        #expect(throws: Never.self) { try policy.authorize(unselected, peer: worker) }
        let audit = LiveMCPGrantAudit()
        let broker = MCPProxyBroker(peer: worker, authorize: { scope, peer in
            audit.record(scope.grantID)
            return try policy.authorize(scope, peer: peer)
        })
        let channel = try await connection.makeMCPControlClient(handler: { await broker.handle($0) }, onClose: { await broker.close() })
        let management = try await connection.makeWorktreeManagementClient()
        try await management.open()
        try await channel.open()
        do {
            #expect(try await channel.send(MCPProxyControl.ready) == MCPProxyControl.ready)
            var skills: [HostAgentSkillRevision] = []
            for runtime in [TeamHookRuntime.codex, .claude] {
                let native = runtime == .codex ? ".agents" : ".claude"
                let snapshot = RemoteSkillSnapshot(runtime: runtime, files: [.init(scope: .user,
                    path: native + "/skills/fixture/SKILL.md", contents: Data("---\nname: fixture\ndescription: Live fixture\n---\nUse the granted fixture server.\n".utf8))])
                _ = try await RemoteSkillTransferSender.transfer(snapshot, repositoryID: remoteRepository, operationID: UUID()) { request in
                    guard case .agentSkills(let result) = try await management.send(.agentSkills(request)) else { throw ProviderError("Skill transfer failed") }
                    return result
                }
                skills.append(.init(runtime: runtime.rawValue, revision: try snapshot.revision))
            }
            let intent = HostPlacementIntent(repositoryID: remoteRepository, worktreeName: String(name), branchName: String(name),
                demand: .init(architecture: "arm64", cpus: 0.5, memoryBytes: 512 << 20, diskBytes: 512 << 20),
                devContainer: .init(skills: skills, mcpGrants: [scope]))
            guard case .error = try await management.send(.placement(.createWithAgentSkills(operationID: operation, intent: intent))) else {
                throw ProviderError("Legacy placement request silently accepted MCP configuration")
            }
            var admission = try await management.send(.placement(.createWithMCP(operationID: operation, intent: intent)))
            for _ in 0..<20 {
                guard case .error(_, let message, _, _) = admission, message.contains("Host admission rejected:") else { break }
                try await Task.sleep(for: .seconds(3))
                admission = try await management.send(.placement(.createWithMCP(operationID: operation, intent: intent)))
            }
            guard case .placement(var record) = admission else { throw ProviderError("Managed MCP admission failed: \(admission)") }
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            while record.state == .preparing && ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(1))
                guard case .placement(let next) = try await management.send(.placement(.status(operationID: operation))) else { throw ProviderError("Placement status missing") }
                record = next
            }
            if let result = ProcessInfo.processInfo.environment["GRAFTTY_LIVE_AWS_RESULT"] {
                try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: result + ".placement"))
            }
            try #require(record.state == .created, "MCP placement failed: \(record.message ?? record.state.rawValue)")
            let environment = try #require(record.environment)
            let home = try #require(environment.agentSkillHome)
            #expect(environment.mcpConfigured == true && !environment.agentReady)
            let python = try String(contentsOf: repository.appendingPathComponent("scripts/linux/live-agent-mcp.py"), encoding: .utf8)
            let quote = WorktreeAgentLaunchCommand.shellLiteral
            let command = ["docker", "exec", "-i", "-u", "ubuntu", "-w", environment.remoteWorkspaceFolder,
                environment.containerID, "env", "HOME=" + home, "GRAFTTY_SOCK=" + MCPProfileMount.containerSocket,
                "python3", "-", home, MCPProfileMount.containerExecutable, "--installed-profile", "--unselected-scope-json",
                String(decoding: try JSONEncoder().encode(unselected), as: UTF8.self)].map(quote).joined(separator: " ")
            let script = "set -eu\n" + command + " <<'GRAFTTY_CONTAINER_MCP'\n" + python + "\nGRAFTTY_CONTAINER_MCP\n"
            var output = try await runRemoteProbe(script, target: target, root: root)
            // Native settings and mounted socket survive a container restart.
            output += try await runRemoteProbe("set -eu\ndocker restart " + quote(environment.containerID) + " >/dev/null\n" + script,
                target: target, root: root)
            #expect(try String(contentsOf: marker, encoding: .utf8) == "parent executed\nparent executed\n")
            #expect(!audit.contains(unselected.grantID), "An unselected grant reached the parent through the profile socket")
            guard case .deleted = try await management.send(.delete(worktreeID: scope.worktreePath, force: true)) else { throw ProviderError("Managed MCP cleanup failed") }
            let endpoint = "/run/user/1000/graftty/mcp/" + operation.uuidString.lowercased() + "/bridge.sock"
            _ = try await runRemoteProbe("set -eu\ntest ! -e " + quote(endpoint) + "\ntest -f " + quote(home + "/.codex/config.toml") + "\n",
                target: target, root: root)
            if let result = ProcessInfo.processInfo.environment["GRAFTTY_LIVE_AWS_RESULT"] {
                try Data(output.utf8).write(to: URL(fileURLWithPath: result + ".container-mcp"))
            }
            management.close(); channel.close(); await broker.close()
        } catch { management.close(); channel.close(); await broker.close(); throw error }
    }
}

/// Records authorization attempts, not tool payloads or credentials.
private final class LiveMCPGrantAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var grants: Set<UUID> = []
    func record(_ id: UUID) { lock.withLock { _ = grants.insert(id) } }
    func contains(_ id: UUID) -> Bool { lock.withLock { grants.contains(id) } }
}
