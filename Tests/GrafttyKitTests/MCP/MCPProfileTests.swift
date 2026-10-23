import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@MainActor struct MCPProfileTests {
    @Test("@spec REMOTE-30.13: While serving a managed profile MCP socket, the application shall reject general host commands, other parents, unselected grants and sessions opened through another profile, and close its sessions when the endpoint stops.")
    func profileEndpointRestrictsAuthority() async throws {
        let parent = RemoteMacConnectionSummary.ID(deviceID: .init(value: "parent"),
            fingerprint: RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 7, count: 32))))
        let scope = MCPProxyScope(grantID: UUID(), generation: 1, repositoryID: UUID(), worktreePath: "/project/.worktrees/task", serverID: "fixture")
        let spy = ProfileSender()
        let gate = MCPProfileGate(configurations: [.init(parent: parent, scope: scope)], send: { await spy.send($0) })
        let id = UUID()
        #expect(await gate.handle(.mcpBridge(.init(parent: parent, request: .open(sessionID: id, scope: scope)))) == .mcpProxy(.opened))
        var changed = scope; changed.generation += 1
        #expect(await gate.handle(.mcpBridge(.init(parent: parent, request: .open(sessionID: UUID(), scope: changed)))) == .mcpProxy(.error(.unauthorized)))
        #expect(await gate.handle(.mcpBridge(.init(parent: parent, request: .receive(sessionID: UUID())))) == .mcpProxy(.error(.unauthorized)))
        let other = RemoteMacConnectionSummary.ID(deviceID: .init(value: "other"), fingerprint: parent.fingerprint)
        #expect(await gate.handle(.mcpBridge(.init(parent: other, request: .receive(sessionID: id)))) == .mcpProxy(.error(.unauthorized)))
        #expect(await gate.handle(.listPanes(path: "/project")) == .error("This socket only serves this profile's MCP grants"))
        #expect(await spy.count == 1)
        await gate.stop()
        #expect(await spy.count == 2)
        #expect(await gate.handle(.mcpBridge(.init(parent: parent, request: .receive(sessionID: id)))) == .mcpProxy(.error(.unavailable)))
    }

    @Test("@spec REMOTE-30.15: When a managed MCP endpoint stops, the application shall remove its socket while retaining the mount directory, and shall recreate the endpoint only from host-supplied assignment configuration.")
    func endpointLifecycleRetainsMountDirectory() async throws {
        let root = URL(fileURLWithPath: "/tmp/mp-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["runtime/bin/graftty", "runtime/libexec/graftty-cli"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let parent = RemoteMacConnectionSummary.ID(deviceID: .init(value: "parent"),
            fingerprint: RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 7, count: 32))))
        let scope = MCPProxyScope(grantID: UUID(), generation: 1, repositoryID: UUID(), worktreePath: "/project", serverID: "fixture")
        let service = MCPProfileService(directory: root.appendingPathComponent("s"), runtime: root.appendingPathComponent("runtime"), send: { _ in .opened })
        let id = UUID()
        let configurations = [MCPBridgeConfiguration(parent: parent, scope: scope)]
        let mount = try service.prepare(operationID: id, configurations: configurations)
        let before = try FileManager.default.attributesOfItem(atPath: mount.directory)[.systemFileNumber] as? NSNumber
        #expect(FileManager.default.fileExists(atPath: mount.directory + "/bridge.sock"))
        #expect(throws: (any Error).self) { try service.prepare(operationID: id, configurations: configurations) }
        await service.stop(operationID: id)
        #expect(!FileManager.default.fileExists(atPath: mount.directory + "/bridge.sock"))
        #expect(try FileManager.default.attributesOfItem(atPath: mount.directory)[.systemFileNumber] as? NSNumber == before)
        let recreated = try service.prepare(operationID: id, configurations: configurations)
        #expect(recreated.directory == mount.directory)
        await service.stop()
    }

    @Test func rejectedOpenCannotClaimAnotherProfilesSession() async throws {
        let parent = RemoteMacConnectionSummary.ID(deviceID: .init(value: "parent"),
            fingerprint: RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 7, count: 32))))
        let scope = MCPProxyScope(grantID: UUID(), generation: 1, repositoryID: UUID(), worktreePath: "/project", serverID: "fixture")
        let gate = MCPProfileGate(configurations: [.init(parent: parent, scope: scope)], send: { request in
            if case .open = request.request { return .error(.invalidRequest) }
            Issue.record("A rejected open reached another session")
            return .accepted
        })
        let id = UUID()
        _ = await gate.handle(.mcpBridge(.init(parent: parent, request: .open(sessionID: id, scope: scope))))
        #expect(await gate.handle(.mcpBridge(.init(parent: parent, request: .receive(sessionID: id)))) == .mcpProxy(.error(.unauthorized)))
        await gate.stop()
    }

    @Test("@spec REMOTE-30.14: When a managed container installs MCP configuration, the application shall generate native entries in its fresh private profile, preserve existing files, and mount only its dedicated socket directory and the bridge runtime read-only.")
    func installsNativeConfigurationWithoutOverwriting() async throws {
        let fixture = try SkillFixture(); defer { fixture.remove() }
        let parent = RemoteMacConnectionSummary.ID(deviceID: .init(value: "parent"),
            fingerprint: RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 7, count: 32))))
        let scope = MCPProxyScope(grantID: UUID(), generation: 1, repositoryID: UUID(), worktreePath: fixture.root.path, serverID: "fixture")
        let setup = MCPProfileMount(directory: "/private/profile-socket", runtime: "/opt/host-runtime", configurations: [.init(parent: parent, scope: scope)])
        #expect(setup.mounts == [ "type=bind,source=/private/profile-socket,target=/run/graftty-mcp,readonly", "type=bind,source=/opt/host-runtime,target=/opt/graftty-mcp,readonly"])
        let home = fixture.root.appendingPathComponent("home").path
        let script = try setup.installationScript(home: home)
        let runner = CLIRunner()
        _ = try await runner.run(command: "/bin/sh", args: ["-c", script], at: fixture.root.path)
        let codex = try String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8)
        #expect(codex.contains("/opt/graftty-mcp/bin/graftty"))
        #expect(codex.contains("/run/graftty-mcp/bridge.sock"))
        #expect(try String(contentsOfFile: home + "/.claude/.claude.json", encoding: .utf8).contains("mcpServers"))
        await #expect(throws: (any Error).self) { _ = try await runner.run(command: "/bin/sh", args: ["-c", script], at: fixture.root.path) }
        #expect(try String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8) == codex)
    }
}

private actor ProfileSender {
    var count = 0
    func send(_ request: MCPBridgeRequest) -> MCPProxyResponse {
        count += 1
        switch request.request { case .open: return .opened; case .close: return .closed; default: return .accepted }
    }
}
