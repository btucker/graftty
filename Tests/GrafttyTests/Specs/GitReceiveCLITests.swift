import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

#if os(macOS)
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
#endif
