import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

#if os(macOS)
import CryptoKit
import GrafttyHostAgent
import GrafttyRemoteClient

private final class GitReceiveCLITestBundleAnchor: NSObject {}

@Suite
struct GitReceiveCLITests {
    @Test("@spec REMOTE-26.12: When a delegated Git receive hook validates a push, the application shall recheck the authenticated assignment and every proposed ref before Git updates any ref, and reject deletions and non-commit targets.")
    func nativeReceiveRejectsMixedRefsAndRevokedAssignments() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("git-receive-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), received = root.appendingPathComponent("received.git")
        _ = try await GitRunner.run(args: ["init", "--initial-branch=main", source.path], at: root.path)
        _ = try await GitRunner.run(args: ["init", "--bare", received.path], at: root.path)
        let store = GitDelegationStore(directory: root.appendingPathComponent("authority"))
        let peer = RemoteMacConnectionSummary.ID(deviceID: .init(value: "worker"), fingerprint: try .init(rawBytes: Data(repeating: 1, count: 32)))
        let delegation = GitDelegation(id: UUID(), generation: 1, repositoryID: UUID(), host: peer,
            remoteWorktreeID: "/remote/project/.worktrees/task", allowedRefs: ["refs/heads/task"], expiresAt: Date().addingTimeInterval(3600))
        try store.install(delegation)
        let context = GitReceiveHookContext(delegationDirectory: store.directory.path, repositoryPath: received.path,
            scope: .init(delegationID: delegation.id, generation: 1, repositoryID: delegation.repositoryID,
                         remoteWorktreeID: delegation.remoteWorktreeID, refs: delegation.allowedRefs), authenticatedPeer: peer)
        let contextFile = root.appendingPathComponent("receive.json")
        try JSONEncoder().encode(context).write(to: contextFile)
        let script = GitReceiveHook.script(executable: try executable().path, contextFile: contextFile.path)
        let hook = received.appendingPathComponent("hooks/pre-receive")
        try Data(script.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        _ = try await GitRunner.run(args: ["-c", "user.name=Receive Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "one"], at: source.path)
        _ = try await GitRunner.run(args: ["push", received.path, "HEAD:refs/heads/task"], at: source.path)
        let initial = try await GitRunner.run(args: ["rev-parse", "refs/heads/task"], at: received.path)
        _ = try await GitRunner.run(args: ["-c", "user.name=Receive Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "two"], at: source.path)
        // Even without --atomic, pre-receive rejects the complete update set.
        let mixed = try await GitRunner.captureAll(args: ["push", received.path, "HEAD:refs/heads/task", "HEAD:refs/heads/foreign"], at: source.path)
        #expect(mixed.exitCode != 0)
        #expect(try await GitRunner.run(args: ["rev-parse", "refs/heads/task"], at: received.path) == initial)
        #expect(try await GitRunner.capture(args: ["show-ref", "--verify", "--quiet", "refs/heads/foreign"], at: received.path).exitCode != 0)
        #expect(try await GitRunner.capture(args: ["push", received.path, ":refs/heads/task"], at: source.path).exitCode != 0)
        _ = try await GitRunner.run(args: ["-c", "user.name=Receive Test", "-c", "user.email=test@example.invalid", "tag", "-a", "annotated", "-m", "tag"], at: source.path)
        #expect(try await GitRunner.capture(args: ["push", "--force", received.path, "refs/tags/annotated:refs/heads/task"], at: source.path).exitCode != 0)
        try store.revoke(id: delegation.id, generation: 1)
        #expect(try await GitRunner.capture(args: ["push", received.path, "HEAD:refs/heads/task"], at: source.path).exitCode != 0)
        #expect(try await GitRunner.run(args: ["rev-parse", "refs/heads/task"], at: received.path) == initial)
        #expect(try await GitRunner.run(args: ["branch", "--show-current"], at: source.path).trimmingCharacters(in: .whitespacesAndNewlines) == "main")
    }

    @Test("@spec REMOTE-26.13: When preparing a delegated Git receiver, the parent shall authenticate its scope before creating storage, isolate each assignment generation in a bare repository, and require its own receive hook without inheriting caller Git configuration.", arguments: [GitReplicaObjectFormat.sha1, .sha256])
    func receiverUsesPrivateBareStorageAndFreshAuthority(format: GitReplicaObjectFormat) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("git replica \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        _ = try await GitRunner.run(args: ["init", "--initial-branch=main", "--object-format=" + format.rawValue, source.path], at: root.path)
        _ = try await GitRunner.run(args: ["-c", "user.name=Replica Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "one"], at: source.path)
        let authority = GitDelegationStore(directory: root.appendingPathComponent("authority"))
        let peer = RemoteMacConnectionSummary.ID(deviceID: .init(value: "worker"), fingerprint: try .init(rawBytes: Data(repeating: 1, count: 32)))
        let delegation = GitDelegation(id: UUID(), generation: 1, repositoryID: UUID(), host: peer,
            remoteWorktreeID: "/remote/task", allowedRefs: ["refs/heads/task"], expiresAt: Date().addingTimeInterval(600))
        try authority.install(delegation)
        let scope = GitDelegationScope(delegationID: delegation.id, generation: 1, repositoryID: delegation.repositoryID,
            remoteWorktreeID: delegation.remoteWorktreeID, refs: delegation.allowedRefs)
        let storage = root.appendingPathComponent("replicas")
        let replicas = GitReplicaStore(directory: storage, delegations: authority, cliExecutable: try executable())
        let wrongPeer = RemoteMacConnectionSummary.ID(deviceID: peer.deviceID, fingerprint: try .init(rawBytes: Data(repeating: 2, count: 32)))
        await #expect(throws: (any Error).self) { try await replicas.prepareReceive(scope: scope, authenticatedPeer: wrongPeer, objectFormat: format) }
        #expect(!FileManager.default.fileExists(atPath: storage.path))
        let receiver = try await replicas.prepareReceive(scope: scope, authenticatedPeer: peer, objectFormat: format)
        #expect(try await GitRunner.run(args: ["rev-parse", "--is-bare-repository"], at: receiver.repository.path) == "true\n")
        let script = root.appendingPathComponent("receive")
        try Data(receiver.shellCommand.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        _ = try await GitRunner.run(args: ["push", "--receive-pack=" + WorktreeAgentLaunchCommand.shellLiteral(script.path), receiver.repository.path, "HEAD:refs/heads/task"], at: source.path)
        let sourceCommit = try await GitRunner.run(args: ["rev-parse", "HEAD"], at: source.path)
        #expect(try await GitRunner.run(args: ["rev-parse", "refs/heads/task"], at: receiver.repository.path) == sourceCommit)
        #expect(try await GitRunner.run(args: ["branch", "--show-current"], at: source.path) == "main\n")
        let again = try await replicas.prepareReceive(scope: scope, authenticatedPeer: peer, objectFormat: format)
        #expect(again.repository == receiver.repository)
        #expect(again.hooksDirectory != receiver.hooksDirectory)
        let next = GitDelegation(id: delegation.id, generation: 2, repositoryID: delegation.repositoryID, host: peer,
            remoteWorktreeID: delegation.remoteWorktreeID, allowedRefs: delegation.allowedRefs, expiresAt: delegation.expiresAt)
        try authority.install(next)
        let nextScope = GitDelegationScope(delegationID: next.id, generation: 2, repositoryID: next.repositoryID,
            remoteWorktreeID: next.remoteWorktreeID, refs: next.allowedRefs)
        let successor = try await replicas.prepareReceive(scope: nextScope, authenticatedPeer: peer, objectFormat: format)
        #expect(successor.repository != receiver.repository)
        #expect(try await GitRunner.capture(args: ["show-ref", "--verify", "--quiet", "refs/heads/task"], at: successor.repository.path).exitCode != 0)
        await #expect(throws: (any Error).self) { try await replicas.prepareReceive(scope: scope, authenticatedPeer: peer, objectFormat: format) }
        // A command prepared before reassignment must still run the current-authority hook.
        _ = try await GitRunner.run(args: ["-c", "user.name=Replica Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "two"], at: source.path)
        #expect(try await GitRunner.capture(args: ["-c", "core.hooksPath=/dev/null", "push", "--receive-pack=" + WorktreeAgentLaunchCommand.shellLiteral(script.path), receiver.repository.path, "HEAD:refs/heads/task"], at: source.path).exitCode != 0)
    }

    @Test("@spec REMOTE-26.18: When a host has only replication permission, the parent shall allow authenticated delegated Git requests without granting terminal, worktree-management, browser, or team access, and shall reject replication after its permission is revoked.", .timeLimit(.minutes(1)))
    func authenticatedControlPreparesNativeReceiver() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("git-control-receive-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workerKey = Curve25519.Signing.PrivateKey(), parentKey = Curve25519.Signing.PrivateKey()
        let trusted = TrustedPeerStore(directory: root.appendingPathComponent("trust"))
        let operation = UUID()
        let parent = LinuxHostTrustRequest(deviceID: "parent", displayName: "Mac",
            publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
            serverPublicKey: parentKey.publicKey.rawRepresentation.base64EncodedString())
        let host = LinuxHostIdentity(deviceID: "worker", displayName: "Worker",
            publicKey: workerKey.publicKey.rawRepresentation.base64EncodedString(), port: 8801)
        // Only the AWS command runner is a fixture. Enrollment persistence,
        // trust installation, SSH proof of possession, and scoped receive are real.
        _ = try await AWSHostEnrollment(directory: root.appendingPathComponent("enrollment"), peers: trusted,
            executor: ReceiveEnrollmentExecutor(response: .init(operationID: operation, parent: parent, identity: host)))
            .enroll(operationID: operation, target: .init(profile: "test", accountID: "123456789012", region: "us-east-1",
                instanceID: "i-0123456789abcdef0", user: "ubuntu", executable: "/usr/local/bin/graftty-host",
                stateDirectory: "/home/ubuntu/.local/share/graftty"), parent: parent)
        let worker = try #require(try trusted.get(id: .init(value: host.deviceID)))
        let identity = RemoteMacConnectionSummary.ID(deviceID: worker.id, fingerprint: worker.fingerprint)
        let authority = GitDelegationStore(directory: root.appendingPathComponent("authority"))
        let delegation = GitDelegation(id: UUID(), generation: 1, repositoryID: UUID(), host: identity,
            remoteWorktreeID: "/remote/task", allowedRefs: ["refs/heads/task"], expiresAt: Date().addingTimeInterval(600))
        try authority.install(delegation)
        let replicas = GitReplicaStore(directory: root.appendingPathComponent("replicas"), delegations: authority,
                                       cliExecutable: try executable())
        let broker = GitReceiveBroker(delegations: authority, replicas: replicas)
        let server = DirectSSHHostServer(hostKey: parentKey, trustedPeerStore: trusted,
            streamFactory: { _ in Issue.record("Replication worker reached terminal factory"); throw GitReplicationError.unavailable },
            panesStateSubscribe: { _ in Issue.record("Replication worker subscribed to parent panes"); return .init(cancel: {}) },
            paneControlMutator: { _ in Issue.record("Replication worker reached pane control"); return .ok },
            chromeTabMutator: { _, _, _ in Issue.record("Replication worker reached browser control"); return .init(error: "forbidden") },
            displayOwnershipStore: SessionDisplayOwnershipStore())
        await server.setTeamMessaging(handler: { _, _ in Issue.record("Replication worker reached team messaging"); return Data() },
            onConnect: { _, _ in Issue.record("Replication worker opened team messaging") }, onDisconnect: { _, _ in })
        await server.setGitControl(.init(handler: { peer, bytes in
            let response = await broker.handle(bytes, authenticatedPeer: peer)
            return (try? JSONEncoder().encode(response)) ?? Data()
        }))
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try DirectSSHHostConnection(clientKey: workerKey,
            expectedHostFingerprint: RemoteIdentityFingerprint(of: RemoteIdentityPublicKey(rawRepresentation: parentKey.publicKey.rawRepresentation)))
        do {
            // Worker initiates this connection. The parent receives the actual
            // authenticated worker identity, including on its Git control path.
            try await client.connect(host: "127.0.0.1", port: port)
            await #expect(throws: (any Error).self) { _ = try await client.openTerminalSession(sessionName: "forbidden") }
            await #expect(throws: (any Error).self) { _ = try await client.openTerminalSession(sessionName: "forbidden", preferPaged: true) }
            let control = try await client.makePaneControlClient()
            await #expect(throws: (any Error).self) {
                try await control.open()
                _ = try await control.send(.equalize(target: "forbidden"))
            }
            let management = try await client.makeWorktreeManagementClient()
            await #expect(throws: (any Error).self) { try await management.open() }
            let panes = try await client.makePanesStateClient(onSnapshot: { _ in Issue.record("Worker received parent panes") }, onClosed: { _ in }, requestReply: true)
            await #expect(throws: (any Error).self) { try await panes.open() }
            let team = try await client.makeTeamClient(handler: { _ in Data() }, onClose: {})
            await #expect(throws: (any Error).self) { try await team.open() }
            let chrome = try await client.makeChromeTabClient()
            await #expect(throws: (any Error).self) { try await chrome.open() }
            await #expect(throws: (any Error).self) {
                _ = try await client.openTCPChannel(host: "127.0.0.1", port: port) { $0.eventLoop.makeSucceededVoidFuture() }
            }
            let channel = try await client.makeGitControlClient(handler: { _ in Data() })
            try await channel.open()
            let scope = GitDelegationScope(delegationID: delegation.id, generation: 1, repositoryID: delegation.repositoryID,
                remoteWorktreeID: delegation.remoteWorktreeID, refs: delegation.allowedRefs)
            let request = try JSONEncoder().encode(GitReplicationRequest.prepareReceive(scope: scope, objectFormat: .sha1))
            let bytes = try await channel.send(request)
            let response = try JSONDecoder().decode(GitReplicationResponse.self, from: bytes)
            guard case .receiveReady(let token, _) = response else { throw GitReplicationError.unavailable }
            #expect(!String(decoding: bytes, as: UTF8.self).contains(root.path))
            let receive = try await broker.claim(token, authenticatedPeer: identity)
            // Packs still travel through a local helper in this test. The SSH
            // data channel must authenticate its own claim before starting Git.
            let script = root.appendingPathComponent("receive")
            try Data(receive.shellCommand.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let source = root.appendingPathComponent("source")
            _ = try await GitRunner.run(args: ["init", "--initial-branch=main", source.path], at: root.path)
            _ = try await GitRunner.run(args: ["-c", "user.name=Control Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "one"], at: source.path)
            _ = try await GitRunner.run(args: ["push", "--receive-pack=" + WorktreeAgentLaunchCommand.shellLiteral(script.path), receive.repository.path, "HEAD:refs/heads/task"], at: source.path)
            let sourceCommit = try await GitRunner.run(args: ["rev-parse", "HEAD"], at: source.path)
            #expect(try await GitRunner.run(args: ["rev-parse", "refs/heads/task"], at: receive.repository.path) == sourceCommit)
            try authority.revoke(id: delegation.id, generation: 1)
            let revoked = try await channel.send(request)
            #expect(try JSONDecoder().decode(GitReplicationResponse.self, from: revoked) == .error(.unauthorized))
            var disabled = worker
            disabled.capabilities.replication = .disabled
            try trusted.update(disabled)
            // Existing control requests must recheck the trust store even before
            // an asynchronous connection-registry teardown reaches this channel.
            #expect(try await channel.send(request).isEmpty)
            let reconnect = try DirectSSHHostConnection(clientKey: workerKey,
                expectedHostFingerprint: RemoteIdentityFingerprint(of: RemoteIdentityPublicKey(rawRepresentation: parentKey.publicKey.rawRepresentation)))
            await #expect(throws: (any Error).self) { try await reconnect.connect(host: "127.0.0.1", port: port) }
            await reconnect.close()
            channel.close()
        } catch { await client.close(); await server.close(); await broker.close(); throw error }
        await client.close(); await server.close(); await broker.close()
    }

    private func executable() throws -> URL {
        for location in [Bundle(for: GitReceiveCLITestBundleAnchor.self).bundleURL, URL(fileURLWithPath: CommandLine.arguments[0])] {
            var directory = location.deletingLastPathComponent()
            for _ in 0..<6 {
                let executable = directory.appendingPathComponent("graftty-cli")
                if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
                directory.deleteLastPathComponent()
            }
        }
        throw NSError(domain: "GitReceiveCLITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Build graftty-cli beside its test bundle"])
    }
}
private struct ReceiveEnrollmentExecutor: CLIExecutor {
    let response: ProviderHostEnrollmentResponse
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        let commandID = "11111111-2222-3333-4444-555555555555"
        let instance = "i-0123456789abcdef0"
        let value: [String: Any]
        if args.starts(with: ["sts", "get-caller-identity"]) {
            value = ["Account": "123456789012"]
        } else if args.contains("send-command") {
            value = ["Command": ["CommandId": commandID, "InstanceIds": [instance], "DocumentName": "AWS-RunShellScript"]]
        } else {
            #expect(args.contains("get-command-invocation"))
            value = ["CommandId": commandID, "InstanceId": instance, "DocumentName": "AWS-RunShellScript", "Status": "Success",
                "ResponseCode": 0, "StandardErrorContent": "", "StandardOutputContent": String(decoding: try JSONEncoder().encode(response), as: UTF8.self)]
        }
        return .init(stdout: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), stderr: "", exitCode: 0)
    }
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory)
    }
}
#endif
