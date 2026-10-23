import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import Testing

extension AWSLiveHostTests {
    /// Explicit GRAFTTY_LIVE_AWS_MCP opt-in uses the production worker service,
    /// CLI stdio bridge, SSM SSH transport and native agent MCP discovery.
    func exerciseMCP(connection: DirectSSHHostConnection, target: AWSHostEnrollmentTarget, root: URL,
                     worker: RemoteMacConnectionSummary.ID, parent: RemoteMacConnectionSummary.ID) async throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let marker = root.appendingPathComponent("mcp-parent-marker")
        let credential = root.appendingPathComponent("mcp-parent-credential")
        let secret = "graftty-parent-only-" + UUID().uuidString
        try Data(secret.utf8).write(to: credential)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)
        let remoteDirectory = "/home/ubuntu/mcp-live-" + UUID().uuidString.lowercased()
        let scope = MCPProxyScope(grantID: UUID(), generation: 1, repositoryID: UUID(),
            worktreePath: remoteDirectory + "/workspace", serverID: "fixture")
        let policy = MCPProxyPolicy(servers: ["fixture": .stdio(executable: "/usr/bin/python3",
            arguments: [repository.appendingPathComponent("scripts/linux/mcp-fixture-server.py").path, marker.path, credential.path], environmentKeys: [])],
            grants: [.init(scope: scope, host: worker, expiresAt: Date().addingTimeInterval(240))])
        let broker = MCPProxyBroker(peer: worker, authorize: { try policy.authorize($0, peer: $1) })
        let channel = try await connection.makeMCPControlClient(handler: { await broker.handle($0) }, onClose: { await broker.close() })
        try await channel.open()
        do {
            #expect(try await channel.send(MCPProxyControl.ready) == MCPProxyControl.ready)
            let files = try MCPBridgeFiles.generate([.init(parent: parent, scope: scope)],
                executable: "/home/ubuntu/.local/bin/graftty", configurationDirectory: remoteDirectory,
                socketPath: "/run/user/1000/graftty/graftty.sock")
            let encoded = try JSONEncoder().encode(files).base64EncodedString()
            for bytes in files.values { #expect(!String(decoding: bytes, as: UTF8.self).contains(secret)) }
            let python = try String(contentsOf: repository.appendingPathComponent("scripts/linux/live-agent-mcp.py"), encoding: .utf8)
            let script = """
            set -eu
            umask 077
            mkdir '\(remoteDirectory)'
            trap 'rm -rf "\(remoteDirectory)"' EXIT
            python3 - <<'GRAFTTY_MCP_STAGE'
            import base64, json, pathlib
            root = pathlib.Path('\(remoteDirectory)')
            for name, data in json.loads(base64.b64decode('\(encoded)')).items():
                (root / name).write_bytes(base64.b64decode(data))
            GRAFTTY_MCP_STAGE
            cat > '\(remoteDirectory)/probe.py' <<'GRAFTTY_MCP_PROBE'
            \(python)
            GRAFTTY_MCP_PROBE
            chown -R ubuntu:ubuntu '\(remoteDirectory)'
            runuser -u ubuntu -- env HOME='\(remoteDirectory)' PATH=/usr/local/bin:/usr/bin:/bin GRAFTTY_SOCK=/run/user/1000/graftty/graftty.sock python3 '\(remoteDirectory)/probe.py' '\(remoteDirectory)' /home/ubuntu/.local/bin/graftty
            """
            let output = try await runRemoteProbe(script, target: target, root: root)
            #expect(!output.contains(secret))
            #expect(try String(contentsOf: marker, encoding: .utf8) == "parent executed\n")
            if let file = ProcessInfo.processInfo.environment["GRAFTTY_LIVE_AWS_RESULT"] {
                try Data(output.utf8).write(to: URL(fileURLWithPath: file + ".mcp"))
            }
            channel.close(); await broker.close()
        } catch { channel.close(); await broker.close(); throw error }
    }
}
