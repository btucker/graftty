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
