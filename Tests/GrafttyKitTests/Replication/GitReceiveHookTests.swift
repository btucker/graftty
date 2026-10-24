import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

private struct ReceiveObjectExecutor: CLIExecutor {
    let onObject: @Sendable () throws -> Void
    let objectType: String
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        if args.first == "cat-file" { try onObject() }
        return .init(stdout: args.first == "rev-parse" ? "true\n" : objectType + "\n", stderr: "", exitCode: 0)
    }
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput { try await run(command: command, args: args, at: directory) }
}

@Suite
struct GitReceiveHookTests {
    private let old = String(repeating: "0", count: 40)
    private let new = String(repeating: "a", count: 40)
    @Test func parsesOnlyCompleteBoundedUniqueUpdates() throws {
        let valid = "\(old) \(new) refs/heads/task\n"
        #expect(try GitReceiveHook.parse(Data(valid.utf8)).first?.ref == "refs/heads/task")
        for malformed in ["", String(valid.dropLast()), valid + valid, valid + "\n", "\(old)  \(new) refs/heads/task\n",
                          "\(old) \(new.uppercased()) refs/heads/task\n", "\(old) \(new) HEAD\n",
                          "\(old) \(new) refs/heads/task\u{0}\n", String(repeating: valid, count: 129)] {
            #expect(throws: (any Error).self) { try GitReceiveHook.parse(Data(malformed.utf8)) }
        }
        #expect(throws: GitReceiveHookError.deletionForbidden) { try GitReceiveHook.parse(Data("\(new) \(old) refs/heads/task\n".utf8)) }
        #expect(throws: (any Error).self) { try GitReceiveHook.parse(Data([0xff, 10])) }
        let sha256 = String(repeating: "b", count: 64)
        #expect(try GitReceiveHook.parse(Data("\(sha256) \(sha256) refs/heads/task\n".utf8)).count == 1)
        #expect(throws: (any Error).self) { try GitReceiveHook.parse(Data("\(old) \(sha256) refs/heads/task\n".utf8)) }
    }

    @Test(arguments: ["valid", "revoked", "tag", "blob", "foreign"])
    func checksCurrentAuthorityAfterObjectValidation(mode: String) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("receive-hook-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GitDelegationStore(directory: root)
        let peer = RemoteMacConnectionSummary.ID(deviceID: .init(value: "worker"), fingerprint: try .init(rawBytes: Data(repeating: 1, count: 32)))
        let delegation = GitDelegation(id: UUID(), generation: 1, repositoryID: UUID(), host: peer, remoteWorktreeID: "/project/.worktrees/task",
            allowedRefs: ["refs/heads/task"], expiresAt: Date().addingTimeInterval(600))
        try store.install(delegation)
        let context = GitReceiveHookContext(delegationDirectory: root.path, repositoryPath: "/received.git",
            scope: .init(delegationID: delegation.id, generation: 1, repositoryID: delegation.repositoryID, remoteWorktreeID: delegation.remoteWorktreeID,
                         refs: delegation.allowedRefs), authenticatedPeer: peer)
        let executor = ReceiveObjectExecutor(onObject: {
            if mode == "revoked" { try store.revoke(id: delegation.id, generation: 1) }
            if mode == "foreign" { Issue.record("Unauthorized refs reached object validation") }
        }, objectType: mode == "tag" || mode == "blob" ? mode : "commit")
        let input = Data("\(old) \(new) refs/heads/\(mode == "foreign" ? "foreign" : "task")\n".utf8)
        if mode == "valid" { try await GitReceiveHook.validate(input, context: context, executor: executor) }
        else { await #expect(throws: (any Error).self) { try await GitReceiveHook.validate(input, context: context, executor: executor) } }
    }
}
