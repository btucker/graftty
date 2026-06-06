import Testing
import Foundation
@testable import GrafttyKit

@Suite("PresenceRefSync — git ref round-trip", .serialized)
struct PresenceRefSyncTests {
    private func makeDoc(email: String) -> PresenceDocument {
        PresenceDocument(
            version: 1,
            user: "Sarah",
            email: email,
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            worktrees: [.init(name: "auth-refactor", branch: "auth-refactor", state: .running)]
        )
    }

    @Test("@spec SYNC-2.1: When publishing presence, the application shall push an empty-tree commit carrying the presence JSON in its message to refs/graftty/presence/<slug> on origin, replacing any previous value.")
    func publishCreatesAndReplacesRef() async throws {
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let doc = makeDoc(email: "sarah@example.com")
        try await PresenceRefSync.publish(doc, slug: "sarah-example-com", repoPath: clone.path)

        let lsRemote = try await GitRunner.run(
            args: ["ls-remote", "origin", "refs/graftty/presence/*"], at: clone.path
        )
        #expect(lsRemote.contains("refs/graftty/presence/sarah-example-com"))

        // Publishing again replaces (no non-fast-forward failure).
        let doc2 = PresenceDocument(
            version: 1, user: "Sarah", email: "sarah@example.com",
            updatedAt: Date(timeIntervalSince1970: 1_780_000_100),
            worktrees: []
        )
        try await PresenceRefSync.publish(doc2, slug: "sarah-example-com", repoPath: clone.path)
    }

    @Test("@spec SYNC-2.2: When fetching presence, the application shall mirror refs/graftty/presence/* from origin and decode each document, skipping undecodable refs.")
    func fetchDecodesAllPeerDocs() async throws {
        let (root, cloneA, upstream) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let cloneB = root.appendingPathComponent("cloneB")
        try shellInRepo("git clone \(upstream.path) \(cloneB.path)", at: root)

        let doc = makeDoc(email: "sarah@example.com")
        try await PresenceRefSync.publish(doc, slug: "sarah-example-com", repoPath: cloneB.path)

        // Push a commit whose message is not valid JSON so fetchAll must skip it.
        let junkTree = try await GitRunner.run(
            args: ["hash-object", "-w", "-t", "tree", "/dev/null"], at: cloneB.path
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let junkCommit = try await GitRunner.run(
            args: ["-c", "user.name=x", "-c", "user.email=x@x",
                   "commit-tree", junkTree, "-m", "this is not json"],
            at: cloneB.path
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await GitRunner.run(
            args: ["push", "--quiet", "--force", "origin",
                   "\(junkCommit):refs/graftty/presence/legacy-tool"],
            at: cloneB.path
        )

        let fetched = try await PresenceRefSync.fetchAll(repoPath: cloneA.path)
        #expect(fetched == [doc])
    }

    @Test("@spec SYNC-2.3: When presence sharing is disabled for a repo, the application shall delete the publishing user's presence ref from origin.")
    func deleteRemovesRef() async throws {
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        try await PresenceRefSync.publish(makeDoc(email: "sarah@example.com"), slug: "sarah-example-com", repoPath: clone.path)
        try await PresenceRefSync.delete(slug: "sarah-example-com", repoPath: clone.path)

        let lsRemote = try await GitRunner.run(
            args: ["ls-remote", "origin", "refs/graftty/presence/*"], at: clone.path
        )
        #expect(!lsRemote.contains("sarah-example-com"))
        let fetched = try await PresenceRefSync.fetchAll(repoPath: clone.path)
        #expect(fetched.isEmpty)
    }
}
