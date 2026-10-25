import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite
struct GitDelegationStoreTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private func peer(_ byte: UInt8 = 1, device: String = "worker") throws -> RemoteMacConnectionSummary.ID {
        .init(deviceID: .init(value: device), fingerprint: try .init(rawBytes: Data(repeating: byte, count: 32)))
    }
    private func assignment(id: UUID = UUID(), generation: UInt64 = 1, repository: UUID = UUID(), host: UInt8 = 1,
                            refs: [String] = ["refs/heads/task"], expires: Date? = nil) throws -> GitDelegation {
        .init(id: id, generation: generation, repositoryID: repository, host: try peer(host),
              remoteWorktreeID: "/project/.worktrees/task", allowedRefs: refs, expiresAt: expires ?? now.addingTimeInterval(3600))
    }
    private func directory() -> URL { URL.temporaryDirectory.appendingPathComponent("git-delegation-\(UUID())") }
    private func request(_ assignment: GitDelegation, refs: [String] = ["refs/heads/task"]) -> GitDelegationScope {
        .init(delegationID: assignment.id, generation: assignment.generation, repositoryID: assignment.repositoryID,
              remoteWorktreeID: assignment.remoteWorktreeID, refs: refs)
    }

    @Test("@spec REMOTE-26.10: When a parent records a Git delegation, the application shall persist its expected host identity, repository, worktree, exact allowed refs, generation, and expiry, and reject authentication or scope mismatches.")
    func durableAuthorizationChecksEveryScopeField() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitDelegationStore(directory: root)
        let assignment = try assignment()
        try store.install(assignment, at: now)
        let restored = GitDelegationStore(directory: root)
        #expect(try restored.authorize(request(assignment), authenticatedPeer: peer(), at: now) == assignment)
        #expect(throws: (any Error).self) { try restored.authorize(request(assignment), authenticatedPeer: peer(2), at: now) }
        #expect(throws: (any Error).self) { try restored.authorize(request(assignment), authenticatedPeer: peer(device: "other"), at: now) }
        for scope in [
            GitDelegationScope(delegationID: UUID(), generation: 1, repositoryID: assignment.repositoryID, remoteWorktreeID: assignment.remoteWorktreeID, refs: assignment.allowedRefs),
            GitDelegationScope(delegationID: assignment.id, generation: 2, repositoryID: assignment.repositoryID, remoteWorktreeID: assignment.remoteWorktreeID, refs: assignment.allowedRefs),
            GitDelegationScope(delegationID: assignment.id, generation: 1, repositoryID: UUID(), remoteWorktreeID: assignment.remoteWorktreeID, refs: assignment.allowedRefs),
            GitDelegationScope(delegationID: assignment.id, generation: 1, repositoryID: assignment.repositoryID, remoteWorktreeID: "/another/worktree", refs: assignment.allowedRefs)
        ] {
            #expect(throws: (any Error).self) { try restored.authorize(scope, authenticatedPeer: peer(), at: now) }
        }
        #expect(throws: (any Error).self) { try restored.authorize(request(assignment), authenticatedPeer: peer(), at: assignment.expiresAt) }
    }

    @Test("@spec REMOTE-26.11: When a Git delegation is reassigned or revoked, the application shall reject prior generations and changed retries, retain revocation across restart, and serialize updates from separate parent processes.")
    func reassignmentAndRevocationCannotResurrectOldAuthority() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = GitDelegationStore(directory: root), second = GitDelegationStore(directory: root)
        let old = try assignment()
        try first.install(old, at: now)
        try second.install(old, at: now)
        let changed = try assignment(id: old.id, repository: old.repositoryID, host: 2)
        #expect(throws: (any Error).self) { try second.install(changed, at: now) }
        let next = try assignment(id: old.id, generation: 2, repository: old.repositoryID, host: 2)
        try second.install(next, at: now)
        #expect(throws: (any Error).self) { try first.authorize(request(old), authenticatedPeer: peer(), at: now) }
        #expect(throws: (any Error).self) { try first.install(old, at: now) }
        #expect(try first.authorize(request(next), authenticatedPeer: peer(2), at: now) == next)
        #expect(throws: (any Error).self) { try first.revoke(id: old.id, generation: 1) }
        try first.revoke(id: old.id, generation: 2)
        try second.revoke(id: old.id, generation: 2)
        #expect(throws: (any Error).self) { try second.install(next, at: now) }
        #expect(throws: (any Error).self) { try second.authorize(request(next), authenticatedPeer: peer(2), at: now) }
        let third = try assignment(id: old.id, generation: 3, repository: old.repositoryID)
        try second.install(third, at: now)
        #expect(try first.authorize(request(third), authenticatedPeer: peer(), at: now) == third)
    }

    @Test func simultaneousWritersDoNotLoseDelegations() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let assignments = try (0..<20).map { _ in try assignment() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for assignment in assignments {
                group.addTask { try GitDelegationStore(directory: root).install(assignment, at: now) }
            }
            try await group.waitForAll()
        }
        for assignment in assignments {
            #expect(try GitDelegationStore(directory: root).authorize(request(assignment), authenticatedPeer: peer(), at: now) == assignment)
        }
    }

    @Test func validatesTheWholeRefSetAndPreservesExactBytes() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitDelegationStore(directory: root)
        let assignment = try assignment(refs: ["refs/heads/task", "refs/heads/caf\u{00e9}"])
        try store.install(assignment, at: now)
        for refs in [[], ["refs/heads/task", "refs/heads/foreign"], ["refs/heads/task", "refs/heads/task"],
                     ["refs/heads/task/*"], ["refs/heads/task/../../main"], ["HEAD"], ["refs/heads/cafe\u{0301}"]] {
            #expect(throws: (any Error).self) { try store.authorize(request(assignment, refs: refs), authenticatedPeer: peer(), at: now) }
        }
        #expect(try store.authorize(request(assignment, refs: assignment.allowedRefs), authenticatedPeer: peer(), at: now) == assignment)
    }

    @Test func rejectsInvalidAssignmentsAndNeverOverwritesUnreadableState() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitDelegationStore(directory: root)
        for ref in ["refs/heads/", "refs/tags/v1", "refs/heads/.hidden", "refs/heads/foo.lock", "refs/heads/a..b", "refs/heads/a b", "refs/heads/a@{1}", "refs/heads/a\\b", "refs/heads/a\nb"] {
            #expect(throws: (any Error).self) { try store.install(assignment(refs: [ref]), at: now) }
        }
        #expect(throws: (any Error).self) { try store.install(assignment(generation: 0), at: now) }
        #expect(throws: (any Error).self) { try store.install(assignment(expires: now), at: now) }
        let validAssignment = try assignment()
        try store.install(validAssignment, at: now)
        let file = root.appendingPathComponent("delegations.json")
        let original = try Data(contentsOf: file)
        for broken in [Data("{bad".utf8), Data("{\"version\":99,\"records\":[]}".utf8)] {
            try broken.write(to: file)
            #expect(throws: (any Error).self) { try store.authorize(request(validAssignment), authenticatedPeer: peer(), at: now) }
            #expect(throws: (any Error).self) { try store.install(validAssignment, at: now) }
            #expect(try Data(contentsOf: file) == broken)
        }
        try original.write(to: file)
        #expect(try store.authorize(request(validAssignment), authenticatedPeer: peer(), at: now) == validAssignment)
    }
}
