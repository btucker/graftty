#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
@testable import Graftty
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import Testing
import MCP
#if canImport(Network)
import Network
#endif

@Suite(.serialized)
struct DirectSSHLoopbackTests {
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func replicationOnlyRejectsMobilePeersAndMissingReceiver(configured: Bool) async throws {
        let f = Fixture(); defer { f.cleanup() }
        let peer = TrustedPeer(id: .init(value: "worker"), kind: configured ? .iphone : .linux,
            publicKey: try .init(rawRepresentation: f.clientKey.publicKey.rawRepresentation), displayName: "worker",
            capabilities: .init(terminalControl: .disabled, portTunnel: .disabled, screenView: .disabled,
                                screenControl: .disabled, worktreeManagement: .disabled, replication: .allowed),
            pairedAt: Date(), lastSeenAt: nil)
        try f.store.add(peer)
        let server = f.server()
        if configured { await server.setGitControl(.init(handler: { _, _ in Issue.record("Unauthorized worker reached Git"); return Data() })) }
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        await #expect(throws: (any Error).self) { try await client.connect(host: "127.0.0.1", port: port) }
        await client.close(); await server.close()
    }

    @Test("@spec REMOTE-26.22: When SSH uses a provider proxy's standard streams, the application shall retain host-key pinning, public-key client authentication, and bidirectional control without exposing a local TCP listener.", .timeLimit(.minutes(1)), arguments: [true, false])
    func authenticatesProxyStreams(pinned: Bool) async throws {
        let f = Fixture(); defer { f.cleanup() }
        var peer = try f.peer(key: f.clientKey)
        peer.capabilities.replication = .allowed
        try f.store.add(peer)
        let server = f.server()
        let callback = AsyncStream<Data>.makeStream()
        await server.setGitControl(.init(handler: { _, data in data }, onConnect: { _, session in
            do { callback.continuation.yield(try await session.send(Data("worker callback".utf8))) }
            catch { callback.continuation.finish() }
        }))
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let proxy = Process(), input = Pipe(), output = Pipe()
        proxy.executableURL = URL(fileURLWithPath: "/bin/sh")
        // nc is only the loopback fixture. The production proxy will be aws.
        proxy.arguments = ["-c", "printf 'Starting session with SessionId: fixture\\n'; exec /usr/bin/nc 127.0.0.1 \(port)"]
        proxy.standardInput = input; proxy.standardOutput = output; proxy.standardError = FileHandle.nullDevice
        try proxy.run()
        defer { if proxy.isRunning { proxy.terminate() }; proxy.waitUntilExit() }
        let fingerprint = pinned ? try f.fingerprint : try RemoteIdentityFingerprint(rawBytes: Data(repeating: 7, count: 32))
        let client = try f.client(fingerprint: fingerprint)
        do {
            if pinned {
                try await client.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting)
                let channel = try await client.makeGitControlClient(handler: { bytes in bytes })
                try await channel.open()
                #expect(try await channel.send(Data("parent request".utf8)) == Data("parent request".utf8))
                var iterator = callback.stream.makeAsyncIterator()
                #expect(await iterator.next() == Data("worker callback".utf8))
                channel.close()
            } else {
                await #expect(throws: (any Error).self) { try await client.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting) }
            }
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test("@spec REMOTE-26.26: When a host resource probe receives its first authenticated sidebar snapshot, the application shall timestamp the observation locally, preserve unknown metrics, and fail on timeout or disconnect.", .timeLimit(.minutes(1)), arguments: ["sample", "unknown", "timeout", "disconnect"])
    func probesAuthenticatedResources(mode: String) async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey))
        let sample = HostResourceSnapshot(sampledAt: Date().timeIntervalSince1970, cpuCount: 4, cpuUtilization: 0.25, diskPath: "/workspace")
        let server = DirectSSHHostServer(hostKey: f.hostKey, trustedPeerStore: f.store,
            streamFactory: { _ in DirectEchoTerminalStream() }, panesStateSubscribe: { _ in .init {} },
            panesStateV2Subscribe: { onChange in
                if mode == "sample" || mode == "unknown" {
                    await onChange(.snapshot([], sidebar: .init(projects: [], hostResources: mode == "sample" ? sample : nil)))
                }
                return .init {}
            }, paneControlMutator: { _ in .ok }, displayOwnershipStore: SessionDisplayOwnershipStore())
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            if mode == "sample" {
                let observation = try #require(try await client.resourceObservation())
                #expect(observation.sample == sample)
                #expect(observation.isFresh())
            } else if mode == "unknown" {
                #expect(try await client.resourceObservation() == nil)
            } else if mode == "disconnect" {
                await server.close()
                await #expect(throws: (any Error).self) { _ = try await client.resourceObservation() }
            } else {
                await #expect(throws: (any Error).self) { _ = try await client.resourceObservation(timeout: .milliseconds(50)) }
            }
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test(.timeLimit(.minutes(1))) func pipeBootstrapRejectsFilesWithoutClosingCallerHandles() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let file = f.directory.appendingPathComponent("not-a-pipe")
        try Data("original".utf8).write(to: file)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let output = Pipe()
        let client = try f.client()
        await #expect(throws: (any Error).self) { try await client.connect(input: input, output: output.fileHandleForWriting) }
        #expect(try input.readToEnd() == Data("original".utf8))
        await client.close()
    }

    @Test("@spec REMOTE-30.20: When an app-owned parent MCP transport disconnects, the application shall authenticate a fresh connection, invalidate old worker sessions without replay, and stop reconnecting if provider authorization is revoked.", .timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor func appOwnedMCPReconnectsWithFreshAuthorization(proxy: Bool) async throws {
        let f = Fixture(); defer { f.cleanup() }
        let parentPeer = try f.peer(key: f.clientKey)
        try f.store.add(parentPeer)
        let parent = LinuxHostTrustRequest(deviceID: parentPeer.id.value, displayName: "parent",
            publicKey: f.clientKey.publicKey.rawRepresentation.base64EncodedString())
        let parentID = RemoteMacConnectionSummary.ID(deviceID: parentPeer.id, fingerprint: parentPeer.fingerprint)
        let workerID = RemoteMacConnectionSummary.ID(deviceID: .init(value: "worker"), fingerprint: try f.fingerprint)
        let bridge = MCPWorkerBridge()
        let server = f.server()
        await server.setMCPControl(.init(handler: { _, bytes in bytes }, onConnect: { identity, session in
            await bridge.connected(identity, session: session)
        }, onDisconnect: { _, id in await bridge.disconnected(id) }))
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let operation = UUID()
        let provider = ReconnectingMCPProvider(plan: .init(binding: .init(provider: "fixture", operationID: operation),
            target: "loopback", identity: .init(deviceID: "worker", displayName: "worker",
                publicKey: f.hostKey.publicKey.rawRepresentation.base64EncodedString(), port: port),
            transport: proxy ? .proxy(command: "/usr/bin/nc", arguments: ["127.0.0.1", String(port)]) : .directSSH(host: "127.0.0.1", port: port)))
        let registry = try HostProviderRegistry(providers: [provider])
        let policyFile = f.directory.appendingPathComponent("policy.json")
        let scope = MCPProxyScope(grantID: UUID(), generation: 1, repositoryID: UUID(), worktreePath: "/work", serverID: "fixture")
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let credential = f.directory.appendingPathComponent("credential")
        let marker = f.directory.appendingPathComponent("marker")
        try Data("graftty-parent-only-fixture".utf8).write(to: credential)
        let policy = MCPProxyPolicy(servers: ["fixture": .stdio(executable: "/usr/bin/python3",
            arguments: [repository.appendingPathComponent("scripts/linux/mcp-fixture-server.py").path, marker.path, credential.path], environmentKeys: [])],
            grants: [.init(scope: scope, host: workerID, expiresAt: Date().addingTimeInterval(60))])
        try JSONEncoder().encode(policy).write(to: policyFile)
        let service = MCPConnectionSupervisor(directory: f.directory, retryDelay: .milliseconds(10)) { configuration, ready in
            try await ParentMCPConnection.run(configuration, registry: registry, identity: { (parent, f.clientKey) }, ready: ready)
        }
        func waitFor(_ phase: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(condition(), "\(phase): state=\(service.statuses.first?.state.rawValue ?? "none"), attempts=\(provider.attempts)")
        }
        func callTool(session: UUID, waitForToolReply: Bool = true) async throws {
            for (index, json) in [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"fixture","version":"1"}}}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"touch_parent","arguments":{}}}"#
            ].enumerated() {
                #expect(await bridge.handle(.init(parent: parentID, request: .send(sessionID: session, message: Data(json.utf8)))) == .accepted)
                if index == 1 && !waitForToolReply { return }
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                var received = false
                while ContinuousClock.now < deadline && !received {
                    let response = await bridge.handle(.init(parent: parentID, request: .receive(sessionID: session)))
                    if case .messages(let messages) = response { received = !messages.isEmpty }
                    else { Issue.record("Unexpected MCP response: \(response)"); break }
                    if !received { try await Task.sleep(for: .milliseconds(10)) }
                }
                try #require(received)
                if index == 0 {
                    let initialized = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
                    #expect(await bridge.handle(.init(parent: parentID, request: .send(sessionID: session, message: initialized))) == .accepted)
                }
            }
        }
        do {
            try service.start(.init(provider: "fixture", operationID: operation, policyPath: policyFile.path))
            try await waitFor("initial connection") { service.statuses.first?.state == .connected }
            let old = UUID()
            #expect(await bridge.handle(.init(parent: parentID, request: .open(sessionID: old, scope: scope))) == .opened)
            // The mutation runs, but its result is never received by the worker.
            try await callTool(session: old, waitForToolReply: false)
            try await waitFor("unacknowledged tool execution") { FileManager.default.fileExists(atPath: marker.path) }
            #expect(await f.registry.count == 1)
            await f.registry.revoke(deviceID: parentPeer.id)
            #expect(await f.registry.count == 0)
            try await waitFor("reconnection") { provider.attempts >= 2 && service.statuses.first?.state == .connected }
            #expect(await bridge.handle(.init(parent: parentID, request: .receive(sessionID: old))) == .error(.outcomeUnknown))
            #expect(try String(contentsOf: marker, encoding: .utf8) == "parent executed\n")
            let fresh = UUID()
            #expect(await bridge.handle(.init(parent: parentID, request: .open(sessionID: fresh, scope: scope))) == .opened)
            try await callTool(session: fresh)
            #expect(try String(contentsOf: marker, encoding: .utf8) == "parent executed\nparent executed\n")
            provider.revoke()
            try await waitFor("revocation") { service.statuses.first?.state == .blocked }
            let attempts = provider.attempts
            try await Task.sleep(for: .milliseconds(100))
            #expect(provider.attempts == attempts)
            #expect(await bridge.handle(.init(parent: parentID, request: .receive(sessionID: fresh))) == .error(.outcomeUnknown))
        } catch { await service.shutdown(); await server.close(); throw error }
        await service.shutdown(); await server.close()
    }

    @Test("@spec REMOTE-30.23: While an authenticated interactive connection to the enrolled worker exists, the parent MCP service shall reuse that connection and shall leave its terminal and control channels open when MCP stops.", .timeLimit(.minutes(1)))
    @MainActor func mcpBorrowsInteractiveConnectionWithoutClosingIt() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let peer = try f.peer(key: f.clientKey)
        try f.store.add(peer)
        let parent = LinuxHostTrustRequest(deviceID: peer.id.value, displayName: "parent", publicKey: f.clientKey.publicKey.rawRepresentation.base64EncodedString())
        let bridge = MCPWorkerBridge()
        let server = f.server()
        await server.setMCPControl(.init(handler: { _, bytes in bytes }, onConnect: { identity, session in
            await bridge.connected(identity, session: session)
        }, onDisconnect: { _, id in await bridge.disconnected(id) }))
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let interactive = try f.client()
        let operation = UUID()
        let plan = HostProviderConnection(binding: .init(provider: "fixture", operationID: operation), target: "loopback",
            identity: .init(deviceID: "worker", displayName: "worker", publicKey: f.hostKey.publicKey.rawRepresentation.base64EncodedString(), port: port),
            transport: .directSSH(host: "127.0.0.1", port: port))
        let registry = try HostProviderRegistry(providers: [ReconnectingMCPProvider(plan: plan)])
        let policy = f.directory.appendingPathComponent("policy.json")
        try JSONEncoder().encode(MCPProxyPolicy(servers: [:], grants: [])).write(to: policy)
        let fingerprint = try f.fingerprint
        let service = MCPConnectionSupervisor(directory: f.directory) { configuration, ready in
            try await ParentMCPConnection.run(configuration, registry: registry, existingConnection: { identity in
                #expect(identity.deviceID.value == "worker" && identity.fingerprint == fingerprint)
                return interactive
            }, identity: { (parent, f.clientKey) }, ready: ready)
        }
        do {
            try await interactive.connect(host: "127.0.0.1", port: port)
            let control = try await interactive.makePaneControlClient()
            defer { control.close() }
            try await control.open()
            try service.start(.init(provider: "fixture", operationID: operation, policyPath: policy.path))
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while service.statuses.first?.state != .connected && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(service.statuses.first?.state == .connected)
            #expect(try await control.send(.equalize(target: "before-stop")) == .ok)
            try await service.remove(provider: "fixture", operationID: operation)
            #expect(await interactive.state == .connected)
            #expect(try await control.send(.equalize(target: "after-stop")) == .ok)
        } catch { await service.shutdown(); await interactive.close(); await server.close(); throw error }
        await service.shutdown(); await interactive.close(); await server.close()
    }

    private struct Fixture {
        let directory = URL.temporaryDirectory.appendingPathComponent("direct-ssh-\(UUID())")
        let hostKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let registry = SSHConnectionRegistry()
        var store: TrustedPeerStore { TrustedPeerStore(directory: directory) }
        var fingerprint: RemoteIdentityFingerprint {
            get throws { RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: hostKey.publicKey.rawRepresentation)) }
        }
        func peer(key: Curve25519.Signing.PrivateKey, id: String = "client", allowed: Bool = true, managementAllowed: Bool = true, tunnelAllowed: Bool = false) throws -> TrustedPeer {
            TrustedPeer(id: RemoteDeviceID(value: id), kind: .mac,
                        publicKey: try RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation),
                        displayName: id,
                        capabilities: PairedDeviceCapabilities(terminalControl: allowed ? .allowed : .disabled,
                            portTunnel: tunnelAllowed ? .allowedLoopback : .disabled, screenView: .disabled, screenControl: .disabled,
                            worktreeManagement: managementAllowed ? .allowed : .disabled),
                        pairedAt: Date(), lastSeenAt: nil)
        }
        func server() -> DirectSSHHostServer {
            DirectSSHHostServer(hostKey: hostKey, trustedPeerStore: store,
                streamFactory: { _ in DirectEchoTerminalStream() },
                panesStateSubscribe: { onChange in
                    await onChange(.snapshot([]))
                    return .init(cancel: {})
                }, paneControlMutator: { _ in .ok },
                displayOwnershipStore: SessionDisplayOwnershipStore(), sshConnectionRegistry: registry)
        }
        func client(key: Curve25519.Signing.PrivateKey? = nil, fingerprint: RemoteIdentityFingerprint? = nil) throws -> DirectSSHHostConnection {
            try DirectSSHHostConnection(clientKey: key ?? clientKey, expectedHostFingerprint: fingerprint ?? self.fingerprint)
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test("@spec REMOTE-31.16: When a peer submits a placement request, the host shall bind the request to the SSH-authenticated device and key fingerprint and require worktree-management permission.", .timeLimit(.minutes(1)), arguments: [true, false])
    func placementUsesAuthenticatedIdentity(allowed: Bool) async throws {
        let f = Fixture(); defer { f.cleanup() }
        let peer = try f.peer(key: f.clientKey, managementAllowed: allowed)
        try f.store.add(peer)
        let expected = RemoteMacConnectionSummary.ID(deviceID: peer.id, fingerprint: peer.fingerprint)
        let server = DirectSSHHostServer(hostKey: f.hostKey, trustedPeerStore: f.store,
            streamFactory: { _ in DirectEchoTerminalStream() },
            panesStateSubscribe: { _ in .init(cancel: {}) }, paneControlMutator: { _ in .ok },
            authenticatedPlacementMutator: { _, owner in
                #expect(allowed)
                #expect(owner == expected)
                return .error(code: "test-identity", message: "authenticated", forceAllowed: false, shortStatus: nil)
            }, displayOwnershipStore: SessionDisplayOwnershipStore())
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            if allowed {
                let channel = try await client.makeWorktreeManagementClient()
                try await channel.open()
                let response = try await channel.send(.placement(.status(operationID: UUID())))
                #expect(response == .error(code: "test-identity", message: "authenticated", forceAllowed: false, shortStatus: nil))
            } else {
                await #expect(throws: (any Error).self) {
                    let channel = try await client.makeWorktreeManagementClient()
                    try await channel.open()
                    _ = try await channel.send(.placement(.status(operationID: UUID())))
                }
            }
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func skillSnapshotTransfersOverActualSSHFrames() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey, managementAllowed: true))
        let receiver = RemoteSkillTransferReceiver(directory: f.directory.appendingPathComponent("skills"))
        let server = DirectSSHHostServer(hostKey: f.hostKey, trustedPeerStore: f.store,
            streamFactory: { _ in DirectEchoTerminalStream() }, panesStateSubscribe: { _ in .init(cancel: {}) },
            paneControlMutator: { _ in .ok }, authenticatedSkillMutator: { request, owner in
                do { return .agentSkills(try await receiver.handle(request, owner: owner, repositories: ["/repo"])) }
                catch { return .error(code: "fixture", message: String(describing: error), forceAllowed: false, shortStatus: nil) }
            }, displayOwnershipStore: SessionDisplayOwnershipStore())
        // Team setup rebuilds SSH configuration; it must retain the skill callback.
        await server.setTeamMessaging(handler: { _, _ in Data() }, onConnect: { _, _ in }, onDisconnect: { _, _ in })
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            let channel = try await client.makeWorktreeManagementClient()
            try await channel.open()
            let snapshot = RemoteSkillSnapshot(runtime: .claude, files: [.init(scope: .project, path: ".claude/skills/demo/SKILL.md", contents: Data(repeating: 97, count: 700_000))])
            let id = UUID()
            let result = try await RemoteSkillTransferSender.transfer(snapshot, repositoryID: "/repo", operationID: id) { request in
                let response = try await channel.send(.agentSkills(request))
                guard case .agentSkills(let status) = response else { throw RemoteSkillError("Unexpected SSH fixture response") }
                return status
            }
            #expect(result.phase == .staged)
            #expect(result.descriptor.revision == (try snapshot.revision))
            let peer = try f.peer(key: f.clientKey, managementAllowed: true)
            let parentID = "\(peer.id.value.utf8.count):\(peer.id.value):\(peer.fingerprint.display)"
            // A second stage verifies every byte in the tree written by the RPC receiver.
            _ = try RemoteSkillStore(directory: f.directory.appendingPathComponent("skills"))
                .stage(snapshot, parentID: parentID, projectID: "/repo")
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test("@spec REMOTE-28.13: When a peer transfers agent skills over SSH, the host shall derive its device and fingerprint from authentication and recheck current pairing and worktree-management permission before each request.", .timeLimit(.minutes(1)))
    func skillTransferChecksCurrentAuthenticatedPeer() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let peer = try f.peer(key: f.clientKey, managementAllowed: true)
        try f.store.add(peer)
        let expected = RemoteMacConnectionSummary.ID(deviceID: peer.id, fingerprint: peer.fingerprint)
        let descriptor = RemoteSkillTransferDescriptor(operationID: UUID(), repositoryID: "/repo", runtime: "codex", revision: String(repeating: "0", count: 64), byteCount: 1)
        let server = DirectSSHHostServer(hostKey: f.hostKey, trustedPeerStore: f.store,
            streamFactory: { _ in DirectEchoTerminalStream() },
            panesStateSubscribe: { _ in .init(cancel: {}) }, paneControlMutator: { _ in .ok },
            authenticatedSkillMutator: { request, owner in
                #expect(owner == expected)
                #expect(request == .begin(descriptor))
                return .agentSkills(.init(descriptor: descriptor, receivedBytes: 0, phase: .receiving))
            }, displayOwnershipStore: SessionDisplayOwnershipStore())
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            let channel = try await client.makeWorktreeManagementClient()
            try await channel.open()
            #expect(try await channel.send(.agentSkills(.begin(descriptor))) == .agentSkills(.init(descriptor: descriptor, receivedBytes: 0, phase: .receiving)))
            // Keep the existing SSH channel open to exercise the per-request
            // store check rather than relying on connection teardown alone.
            try f.store.remove(id: peer.id)
            let rejected = try await channel.send(.agentSkills(.finish(operationID: descriptor.operationID)))
            guard case .error(let code, _, _, _) = rejected else { Issue.record("Revoked peer reached skill receiver"); await client.close(); await server.close(); return }
            #expect(code == "skills-forbidden")
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func mcpSubsystemRequiresWorktreePermission() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey, managementAllowed: false))
        let server = f.server()
        await server.setMCPControl(.init(handler: { _, _ in Issue.record("Unpermitted parent reached MCP"); return Data() }))
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            let channel = try await client.makeMCPControlClient(handler: { $0 })
            await #expect(throws: (any Error).self) { try await channel.open() }
            channel.close()
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test("@spec REMOTE-30.11: When a parent opens the MCP subsystem on a managed host, the application shall authenticate both peers and carry standard MCP tool calls back to the parent without granting the worker terminal access to the parent.", .timeLimit(.minutes(1)))
    func mcpReverseProxyExecutesOnParent() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let parentPeer = try f.peer(key: f.clientKey)
        try f.store.add(parentPeer)
        let parent = RemoteMacConnectionSummary.ID(deviceID: parentPeer.id, fingerprint: parentPeer.fingerprint)
        let worker = RemoteMacConnectionSummary.ID(deviceID: .init(value: "worker"), fingerprint: try f.fingerprint)
        let bridge = MCPWorkerBridge()
        let scope = MCPProxyScope(grantID: UUID(), generation: 1, repositoryID: UUID(), worktreePath: "/work/project", serverID: "fixture")
        let marker = f.directory.appendingPathComponent("parent-tool-ran")
        let script = f.directory.appendingPathComponent("server.py")
        try #"""
        import json, sys, pathlib
        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request: continue
            method = request.get("method")
            if method == "initialize":
                result = {"protocolVersion": request["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name":"fixture","version":"1"}}
            elif method == "tools/list":
                result = {"tools":[{"name":"touch_parent","description":"Record execution on parent","inputSchema":{"type":"object","properties":{}}}]}
            elif method == "tools/call":
                pathlib.Path(sys.argv[1]).write_text("parent executed")
                result = {"content":[{"type":"text","text":"parent executed"}]}
            else: result = {}
            print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}), flush=True)
        """#.write(to: script, atomically: true, encoding: .utf8)
        let policy = MCPProxyPolicy(servers: ["fixture": .stdio(executable: "/usr/bin/python3", arguments: [script.path, marker.path], environmentKeys: [])],
            grants: [.init(scope: scope, host: worker, expiresAt: Date().addingTimeInterval(60))])
        let broker = MCPProxyBroker(peer: worker, authorize: { try policy.authorize($0, peer: $1) })
        let server = f.server()
        await server.setMCPControl(.init(handler: { _, bytes in bytes }, onConnect: { identity, session in
            #expect(identity == parent)
            await bridge.connected(identity, session: session)
        }, onDisconnect: { _, id in await bridge.disconnected(id) }))
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let connection = try f.client()
        let transports = await InMemoryTransport.createConnectedPair()
        let nativeClient = MCP.Client(name: "worker-client", version: "1")
        var bridgeTask: Task<Void, Error>?
        // Hard cleanup also bounds SDK requests if an assertion path fails.
        let deadline = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { await broker.close(); await nativeClient.disconnect(); await transports.server.disconnect() }
        }
        defer { deadline.cancel() }
        do {
            try await connection.connect(host: "127.0.0.1", port: port)
            let channel = try await connection.makeMCPControlClient(handler: { await broker.handle($0) }, onClose: { await broker.close() })
            try await channel.open()
            #expect(try await channel.send(MCPProxyControl.ready) == MCPProxyControl.ready)
            try await transports.server.connect()
            bridgeTask = Task {
                try await MCPStdioBridge.run(scope: scope, transport: transports.server) {
                    await bridge.handle(.init(parent: parent, request: $0))
                }
            }
            let initialized = try await nativeClient.connect(transport: transports.client)
            #expect(initialized.serverInfo.name == "fixture")
            let tools = try await nativeClient.listTools()
            #expect(tools.tools.map(\.name) == ["touch_parent"])
            let result = try await nativeClient.callTool(name: "touch_parent")
            #expect(result.isError != true)
            #expect(try String(contentsOf: marker, encoding: .utf8) == "parent executed")
            let unauthorized = await bridge.handle(.init(parent: parent, request: .open(sessionID: UUID(), scope:
                .init(grantID: scope.grantID, generation: 2, repositoryID: scope.repositoryID, worktreePath: scope.worktreePath, serverID: scope.serverID))))
            #expect(unauthorized == .error(.unauthorized))
            channel.close()
        } catch {
            bridgeTask?.cancel(); await nativeClient.disconnect(); await transports.server.disconnect()
            await broker.close(); await connection.close(); await server.close()
            _ = try? await bridgeTask?.value
            throw error
        }
        bridgeTask?.cancel(); await nativeClient.disconnect(); await transports.server.disconnect()
        await broker.close(); await connection.close(); await server.close()
        _ = try? await bridgeTask?.value
    }

    @Test("@spec REMOTE-26.14: When a peer opens the Git control subsystem, the host shall require replication permission, derive the device and key fingerprint from SSH authentication, and keep bidirectional requests on that authenticated connection.", .timeLimit(.minutes(1)), arguments: [true, false], [true, false])
    func gitControlUsesAuthenticatedIdentity(allowed: Bool, configured: Bool) async throws {
        let f = Fixture(); defer { f.cleanup() }
        var peer = try f.peer(key: f.clientKey, managementAllowed: false)
        peer.capabilities.replication = allowed ? .allowed : .disabled
        try f.store.add(peer)
        let expected = RemoteMacConnectionSummary.ID(deviceID: peer.id, fingerprint: peer.fingerprint)
        let server = f.server()
        if configured { await server.setGitControl(.init(handler: { identity, bytes in
            #expect(allowed && configured && identity == expected)
            return bytes
        }, onConnect: { identity, session in
            #expect(allowed && configured && identity == expected)
            do { #expect(try await session.send(Data("reverse request".utf8)) == Data("reverse reply".utf8)) }
            catch { Issue.record(error) }
        })) }
        // Updating team callbacks must retain the independently configured Git subsystem.
        await server.setTeamMessaging(handler: { _, bytes in bytes }, onConnect: { _, _ in }, onDisconnect: { _, _ in })
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            let channel = try await client.makeGitControlClient(handler: { bytes in
                #expect(allowed && configured && bytes == Data("reverse request".utf8))
                return Data("reverse reply".utf8)
            })
            if allowed && configured {
                try await channel.open()
                let claimedIdentity = Data(#"{"deviceID":"forged-host","fingerprint":"forged-key"}"#.utf8)
                #expect(try await channel.send(claimedIdentity) == claimedIdentity)
            } else { await #expect(throws: (any Error).self) { try await channel.open() } }
            channel.close()
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    #if canImport(Network)
    @Test("@spec CHROME-3.3: When a paired client requests a protected Chrome port through direct-tcpip, the application shall refuse the connection and shall restore ordinary listener access after protection ends.", .timeLimit(.minutes(1)))
    func ownedChromePortIsDeniedAtTCPChannelOpen() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey, tunnelAllowed: true))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        let echo = try ForwardEchoServer()
        let echoPort = try await echo.start()
        defer { echo.stop() }
        let token = UUID()
        defer { ChromeDebugPortRegistry.shared.unregister(owner: token) }
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            let payload = Data("ordinary-worktree-or-callback".utf8)
            func roundTrip() async throws -> Data? {
                let forward = try await client.forwardLocalPort(host: "127.0.0.1", port: Int(echoPort))
                defer { forward.stop() }
                let socket = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: forward.localPort)!, using: .tcp)
                socket.start(queue: DispatchQueue(label: "chrome-port-test"))
                defer { socket.cancel() }
                let timeout = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { socket.cancel() } }
                defer { timeout.cancel() }
                try? await BrowserProxy.send(payload, to: socket)
                return try? await forwardReceive(socket, count: payload.count)
            }
            #expect(try await roundTrip() == payload)
            ChromeDebugPortRegistry.shared.register(port: Int(echoPort), owner: token)
            await #expect(throws: (any Error).self) { try await roundTrip() }
            ChromeDebugPortRegistry.shared.unregister(owner: token)
            #expect(try await roundTrip() == payload)
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test("@spec PORTS-5.26: When a paired host allows port tunneling, a local port forward shall relay raw TCP bytes and close sockets when stopped or its parent disconnects.", .timeLimit(.minutes(1)), arguments: [false, true])
    func localPortForwardEchoAndDisconnect(closeParent: Bool) async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey, tunnelAllowed: true))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        let echo = try ForwardEchoServer()
        let echoPort = try await echo.start()
        defer { echo.stop() }
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            let forward = try await client.forwardLocalPort(host: "127.0.0.1", port: Int(echoPort))
            defer { forward.stop() }
            let socket = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: forward.localPort)!, using: .tcp)
            socket.start(queue: DispatchQueue(label: "forward-test-client"))
            defer { socket.cancel() }
            let deadline = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { socket.cancel() } }
            defer { deadline.cancel() }
            let payload = Data("GET / HTTP/1.0\r\n\r\n".utf8)
            try await BrowserProxy.send(payload, to: socket)
            let echoed = try await forwardReceive(socket, count: payload.count)
            #expect(echoed == payload) // A SOCKS greeting must never prefix raw data.
            let closing = ContinuousClock.now
            if closeParent { await client.close() } else { forward.stop() }
            #expect((try? await forwardReceive(socket, count: 1))?.isEmpty != false)
            #expect(closing.duration(to: .now) < .seconds(3))
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test("@spec PORTS-5.28: When a forwarded TCP destination finishes a finite response, the application shall deliver all queued bytes before reporting EOF to the local client.", .timeLimit(.minutes(1)))
    func localPortForwardDrainsFiniteResponse() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey, tunnelAllowed: true))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        let payload = Data(repeating: 0x5a, count: 8 * 1024 * 1024)
        let echo = try ForwardEchoServer(response: payload)
        let echoPort = try await echo.start()
        defer { echo.stop() }
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            let forward = try await client.forwardLocalPort(host: "127.0.0.1", port: Int(echoPort))
            defer { forward.stop() }
            let socket = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: forward.localPort)!, using: .tcp)
            socket.start(queue: DispatchQueue(label: "forward-test-finite"))
            defer { socket.cancel() }
            let deadline = Task { try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled { socket.cancel() } }
            defer { deadline.cancel() }
            try await BrowserProxy.send(Data("GET / HTTP/1.0\r\n\r\n".utf8), to: socket)
            var response = Data()
            while true {
                let (bytes, complete) = await withCheckedContinuation { (continuation: CheckedContinuation<(Data, Bool), Never>) in
                    socket.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, complete, error in
                        continuation.resume(returning: (data ?? Data(), complete || error != nil))
                    }
                }
                response.append(bytes)
                if complete { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(response == payload)
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test("@spec PORTS-5.27: If a host denies tunneling, local port forwarding shall fail before exposing a listener without bypassing host authorization.", .timeLimit(.minutes(1)))
    func localPortForwardRejectsDisabledCapability() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            do {
                let forward = try await client.forwardLocalPort(host: "127.0.0.1", port: 1)
                forward.stop()
                Issue.record("Denied capability must reject the forward before browser launch")
            } catch { }
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }
    #endif

    @Test("@spec REMOTE-20.17: When the direct SSH listener's bind host is a numeric IP address such as `::`, the application shall bind that address without name resolution, so the listener starts on a Linux host with no non-loopback IPv6 address.", .timeLimit(.minutes(1)))
    func numericWildcardBindSkipsNameResolution() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let server = f.server()
        let port = try await server.start(host: "::", port: 0)
        await server.close()
        #expect(port > 0)
    }

    @Test("@spec REMOTE-20.3: When a paired peer connects over direct SSH, the application shall authenticate and dispatch existing Graftty subsystem channels over TCP.", .timeLimit(.minutes(1)))
    func subsystemRoundTrip() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey))
        let server = f.server()
        await server.setTeamMessaging(handler: { _, payload in payload }, onConnect: { _, _ in }, onDisconnect: { _, _ in })
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            let control = try await client.makePaneControlClient()
            try await control.open()
            #expect(try await control.send(.equalize(target: "test-pane")) == .ok)
            control.close()
            let panes = try await client.makePanesStateClient(onSnapshot: { _ in }, onClosed: { _ in }, originAware: true, requestReply: true)
            try await panes.open()
            panes.close()
            let team = try await client.makeTeamClient(handler: { $0 }, onClose: {})
            try await team.open()
            #expect(try await team.send(Data("team-loopback".utf8)) == Data("team-loopback".utf8))
            team.close()
            let terminal = try await client.openTerminalSession(sessionName: "echo", preferPaged: true)
            let deadline = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { terminal.close() } }
            defer { deadline.cancel(); terminal.close() }
            let payload = Data("direct-terminal".utf8)
            try await terminal.send(.binary(payload))
            #expect(try await terminal.receive() == .binary(payload))
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test("@spec REMOTE-20.12: When a direct SSH hostname resolves to IPv4 and IPv6, the application shall authenticate the successful connection without failed address attempts closing its authentication waiter.", .timeLimit(.minutes(1)))
    func hostnameFallbackKeepsWinningAuthentication() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        do {
            try await client.connect(host: "localhost", port: port)
            let control = try await client.makePaneControlClient()
            try await control.open()
            #expect(try await control.send(.equalize(target: "test-pane")) == .ok)
            control.close()
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test("@spec REMOTE-20.4: If a direct SSH host key is unpinned or a peer lacks trust or terminal control, then the application shall reject the connection.", .timeLimit(.minutes(1)))
    func rejectsWrongHostAndUnauthorizedPeers() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        for mode in 0..<3 {
            let key = Curve25519.Signing.PrivateKey()
            if mode != 1 { try f.store.add(f.peer(key: key, id: "peer-\(mode)", allowed: mode != 2)) }
            let fingerprint = mode == 0 ? try RemoteIdentityFingerprint(rawBytes: Data(repeating: 0, count: 32)) : try f.fingerprint
            let client = try f.client(key: key, fingerprint: fingerprint)
            await #expect(throws: (any Error).self) { try await client.connect(host: "127.0.0.1", port: port) }
            await client.close()
        }
        await server.close()
    }

    @Test("@spec REMOTE-20.11: If direct SSH negotiation fails, then the application shall report the original connection error and retain a failed state until teardown is requested.", .timeLimit(.minutes(1)))
    func negotiationFailureRemainsFailed() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client(fingerprint: RemoteIdentityFingerprint(rawBytes: Data(repeating: 0, count: 32)))
        await #expect(throws: PinnedHostKeyError.self) { try await client.connect(host: "127.0.0.1", port: port) }
        if case .failed = await client.state {} else { Issue.record("Negotiation failure became a graceful close") }
        await client.close(); await server.close()
    }

    @Test("@spec REMOTE-20.7: When a paired peer reconnects over direct SSH, the application shall authenticate a fresh session and prevent stale teardown from closing the replacement.", .timeLimit(.minutes(1)))
    func reconnectReplacesOnlySamePeer() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let old = try f.client(); let fresh = try f.client()
        do {
            try await old.connect(host: "127.0.0.1", port: port)
            for _ in 0..<100 where await f.registry.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
            try await fresh.connect(host: "127.0.0.1", port: port)
            for _ in 0..<100 where await old.state != .closed { try await Task.sleep(for: .milliseconds(10)) }
            #expect(await old.state == .closed)
            await old.close()
            let control = try await fresh.makePaneControlClient()
            try await control.open()
            #expect(try await control.send(.equalize(target: "fresh")) == .ok)
            control.close()
            #expect(await f.registry.count == 1)
        } catch { await old.close(); await fresh.close(); await server.close(); throw error }
        await old.close(); await fresh.close(); await server.close()
    }

    @Test("@spec REMOTE-20.10: While a peer is authenticated over direct SSH, the application shall enforce its worktree management and port tunnel capabilities for each channel.", .timeLimit(.minutes(1)))
    func channelCapabilitiesAreEnforced() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey, managementAllowed: false))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            let management = try await client.makeWorktreeManagementClient()
            await #expect(throws: (any Error).self) { try await management.open() }
            management.close()
            await #expect(throws: (any Error).self) {
                _ = try await client.openTCPChannel(host: "127.0.0.1", port: port) { child in child.eventLoop.makeSucceededVoidFuture() }
            }
            let control = try await client.makePaneControlClient()
            try await control.open(); control.close()
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test("@spec REMOTE-20.5: While distinct paired peers use direct SSH, the application shall keep their connections independent and close revoked peers before rejecting fresh authentication.", .timeLimit(.minutes(1)))
    func concurrentPeersAndRevocation() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let otherKey = Curve25519.Signing.PrivateKey()
        try f.store.add(f.peer(key: f.clientKey))
        try f.store.add(f.peer(key: otherKey, id: "other"))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let first = try f.client(); let other = try f.client(key: otherKey)
        do {
            try await first.connect(host: "127.0.0.1", port: port)
            try await other.connect(host: "127.0.0.1", port: port)
            // Auth registration is asynchronous; wait for both registry entries.
            for _ in 0..<100 where await f.registry.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(await f.registry.count == 2)
            try f.store.remove(id: .init(value: "client"))
            await f.registry.revoke(deviceID: .init(value: "client"))
            for _ in 0..<100 where await first.state == .connected { try await Task.sleep(for: .milliseconds(10)) }
            #expect(await first.state.isTerminal)
            let control = try await other.makePaneControlClient()
            try await control.open(); control.close()
            let retry = try f.client()
            await #expect(throws: (any Error).self) { try await retry.connect(host: "127.0.0.1", port: port) }
            await retry.close()
        } catch { await first.close(); await other.close(); await server.close(); throw error }
        await first.close(); await other.close(); await server.close()
    }
}

private final class DirectEchoTerminalStream: GrafttyKit.TerminalByteStream, Sendable {
    let inboundBytes: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    init() {
        let stream = AsyncStream<Data>.makeStream()
        inboundBytes = stream.stream; continuation = stream.continuation
    }
    func send(_ bytes: Data) async throws { continuation.yield(bytes) }
    func close() async { continuation.finish() }
}

#if canImport(Network)
private func forwardReceive(_ socket: NWConnection, count: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        socket.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: data ?? Data()) }
        }
    }
}

private final class ForwardEchoServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "forward-test-echo")
    private var sockets: [NWConnection] = []
    private let response: Data?
    init(response: Data? = nil) throws {
        self.response = response
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                if case .ready = state, let port = listener.port {
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: port.rawValue)
                } else if case .failed(let error) = state {
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            listener.newConnectionHandler = { [self] socket in
                sockets.append(socket)
                socket.start(queue: queue)
                socket.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    guard let data, !data.isEmpty else { socket.cancel(); return }
                    if let response = self.response {
                        socket.send(content: response, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in })
                    } else {
                        socket.send(content: data, completion: .contentProcessed { _ in })
                    }
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        queue.async { [self] in
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            sockets.forEach { $0.cancel() }
            sockets.removeAll()
        }
    }
}
#endif

private final class ReconnectingMCPProvider: HostProvider, @unchecked Sendable {
    let identifier = "fixture"
    let plan: HostProviderConnection
    private let lock = NSLock()
    private var revoked = false
    private var count = 0
    var attempts: Int { lock.withLock { count } }
    init(plan: HostProviderConnection) { self.plan = plan }
    func revoke() { lock.withLock { revoked = true } }
    func prepareConnection(operationID: UUID, parent: LinuxHostTrustRequest) async throws -> HostProviderConnection {
        lock.withLock { count += 1 }
        try authorize(plan, parent: parent)
        return plan
    }
    func authorize(_ connection: HostProviderConnection, parent: LinuxHostTrustRequest) throws {
        guard lock.withLock({ !revoked }) else { throw HostProviderConnectionError.authorization }
    }
}
