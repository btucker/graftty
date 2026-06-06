import Testing
import Foundation
@testable import GrafttyKit

@MainActor
@Suite("Presence end to end over a real shared remote", .serialized)
struct PresenceEndToEndTests {
    @Test("Two clones of one upstream exchange presence through git presence refs.")
    func twoClonesExchangePresence() async throws {
        let (root, cloneA, upstream) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let cloneB = root.appendingPathComponent("cloneB")
        try shellInRepo("git clone \(upstream.path) \(cloneB.path)", at: root)
        try shellInRepo("git config user.name 'Ben' && git config user.email 'ben@btucker.net'", at: cloneA)
        try shellInRepo("git config user.name 'Sarah' && git config user.email 'sarah@example.com'", at: cloneB)

        // Sarah (cloneB) publishes via her own sync service (production defaults).
        let storeB = TeamPresenceSyncStore()
        let syncB = TeamPresenceSync(store: storeB)
        var repoB = RepoEntry(path: cloneB.path, displayName: "repo")
        repoB.presenceSharingEnabled = true
        var wtB = WorktreeEntry(path: cloneB.path + "/wt/auth-refactor", branch: "auth-refactor")
        wtB.state = .running
        repoB.worktrees = [wtB]
        await syncB.tick(repos: [repoB])

        // Ben (cloneA) ticks and sees Sarah's worktree, not his own.
        let storeA = TeamPresenceSyncStore()
        let syncA = TeamPresenceSync(store: storeA)
        var repoA = RepoEntry(path: cloneA.path, displayName: "repo")
        repoA.presenceSharingEnabled = true
        var wtA = WorktreeEntry(path: cloneA.path + "/wt/multi-user", branch: "multi-user")
        wtA.state = .running
        repoA.worktrees = [wtA]
        await syncA.tick(repos: [repoA])

        let entries = storeA.remoteWorktrees[cloneA.path] ?? []
        #expect(entries.map(\.ownerName) == ["Sarah"])
        #expect(entries.map(\.branch) == ["auth-refactor"])
        #expect(entries.map(\.state) == [.running])
    }
}
