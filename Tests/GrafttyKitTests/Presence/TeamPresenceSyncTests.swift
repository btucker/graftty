import Testing
import Foundation
@testable import GrafttyKit

@MainActor
@Suite("TeamPresenceSync -- tick behavior")
struct TeamPresenceSyncTests {
    private static let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeRepo(path: String = "/tmp/repo", sharing: Bool) -> RepoEntry {
        var repo = RepoEntry(path: path, displayName: "repo")
        repo.presenceSharingEnabled = sharing
        var wt = WorktreeEntry(path: path + "/wt/feature-x", branch: "feature-x")
        wt.state = .running
        repo.worktrees = [wt]
        return repo
    }

    private func makeSync(
        store: TeamPresenceSyncStore,
        identity: PresenceIdentity = PresenceIdentity(name: "Ben", email: "ben@btucker.net"),
        published: PublishLog = PublishLog(),
        fetchResult: [PresenceDocument] = []
    ) -> TeamPresenceSync {
        let fixedNow = Self.now
        return TeamPresenceSync(
            store: store,
            identityProvider: { _ in identity },
            publisher: { doc, slug, repoPath in await published.append((doc, slug, repoPath)) },
            fetcher: { _ in fetchResult },
            now: { fixedNow }
        )
    }

    @Test("@spec SYNC-3.1: While presence sharing is disabled for a repo, the application shall neither publish nor fetch presence for that repo.")
    func disabledRepoIsSkipped() async {
        let store = TeamPresenceSyncStore()
        let published = PublishLog()
        let sync = makeSync(store: store, published: published,
                            fetchResult: [PresenceDocument(version: 1, user: "Sarah", email: "s@x.io", updatedAt: Self.now, worktrees: [])])
        await sync.tick(repos: [makeRepo(sharing: false)])
        #expect(await published.count == 0)
        #expect(store.remoteWorktrees.isEmpty)
    }

    @Test("@spec SYNC-3.2: When updating the remote-worktree store, the application shall exclude the local user's own presence document.")
    func ownDocumentExcluded() async {
        let store = TeamPresenceSyncStore()
        let mine = PresenceDocument(version: 1, user: "Ben", email: "ben@btucker.net", updatedAt: Self.now,
                                    worktrees: [.init(name: "multi-user", branch: "multi-user", state: .running)])
        let theirs = PresenceDocument(version: 1, user: "Sarah", email: "sarah@example.com", updatedAt: Self.now,
                                      worktrees: [.init(name: "auth-refactor", branch: "auth-refactor", state: .running)])
        let sync = makeSync(store: store, fetchResult: [mine, theirs])
        await sync.tick(repos: [makeRepo(sharing: true)])

        let entries = store.remoteWorktrees["/tmp/repo"] ?? []
        #expect(entries.count == 1)
        #expect(entries.first?.ownerName == "Sarah")
        #expect(entries.first?.branch == "auth-refactor")
    }

    @Test("@spec SYNC-3.3: If the published worktree set is unchanged and the last publish is younger than the 10-minute heartbeat interval, then the application shall not push again; once the heartbeat interval elapses, the application shall republish so updatedAt outruns teammates' staleness cutoff.")
    func unchangedDocRepublishedOnlyAfterHeartbeat() async {
        let store = TeamPresenceSyncStore()
        let published = PublishLog()
        let clock = MutableClock(now: Self.now)
        let sync = TeamPresenceSync(
            store: store,
            identityProvider: { _ in PresenceIdentity(name: "Ben", email: "ben@btucker.net") },
            publisher: { doc, slug, repoPath in await published.append((doc, slug, repoPath)) },
            fetcher: { _ in [] },
            now: { clock.now }
        )
        let repo = makeRepo(sharing: true)

        await sync.tick(repos: [repo])           // initial publish
        await sync.tick(repos: [repo])           // unchanged, fresh -> skipped
        #expect(await published.count == 1)

        clock.advance(by: TeamPresenceSync.heartbeatInterval + 1)
        await sync.tick(repos: [repo])           // unchanged but heartbeat due -> republish
        #expect(await published.count == 2)
    }

    @Test("@spec SYNC-3.4: If a fetched presence document is older than 30 minutes, then the application shall omit it from the remote-worktree store.")
    func staleDocumentsOmitted() async {
        let store = TeamPresenceSyncStore()
        let fresh = PresenceDocument(version: 1, user: "Sarah", email: "sarah@example.com",
                                     updatedAt: Self.now.addingTimeInterval(-60),
                                     worktrees: [.init(name: "fresh", branch: "fresh", state: .idle)])
        let stale = PresenceDocument(version: 1, user: "Marco", email: "marco@example.com",
                                     updatedAt: Self.now.addingTimeInterval(-31 * 60),
                                     worktrees: [.init(name: "old", branch: "old", state: .idle)])
        let sync = makeSync(store: store, fetchResult: [fresh, stale])
        await sync.tick(repos: [makeRepo(sharing: true)])

        let entries = store.remoteWorktrees["/tmp/repo"] ?? []
        #expect(entries.map(\.ownerName) == ["Sarah"])
    }

    @Test("Publish fires immediately when the worktree set changes, without waiting for the heartbeat.")
    func publishOnWorktreeChange() async {
        let store = TeamPresenceSyncStore()
        let published = PublishLog()
        let sync = makeSync(store: store, published: published)
        var repo = makeRepo(sharing: true)

        await sync.tick(repos: [repo])           // initial publish
        #expect(await published.count == 1)

        // Mutate the worktree set (add a second branch) without advancing the clock.
        let extraWt = WorktreeEntry(path: "/tmp/repo/wt/extra-branch", branch: "extra-branch")
        repo.worktrees.append(extraWt)

        await sync.tick(repos: [repo])           // worktrees changed -> immediate republish
        #expect(await published.count == 2)
    }

    @Test("Remote entries are sorted by owner then name for stable rendering.")
    func entriesSorted() async {
        let store = TeamPresenceSyncStore()
        let sarah = PresenceDocument(version: 1, user: "Sarah", email: "sarah@example.com", updatedAt: Self.now,
                                     worktrees: [.init(name: "zeta", branch: "zeta", state: .idle),
                                                 .init(name: "alpha", branch: "alpha", state: .idle)])
        let marco = PresenceDocument(version: 1, user: "Marco", email: "marco@example.com", updatedAt: Self.now,
                                     worktrees: [.init(name: "beta", branch: "beta", state: .idle)])
        let sync = makeSync(store: store, fetchResult: [sarah, marco])
        await sync.tick(repos: [makeRepo(sharing: true)])

        let entries = store.remoteWorktrees["/tmp/repo"] ?? []
        #expect(entries.map(\.name) == ["beta", "alpha", "zeta"])
    }
}

/// Thread-safe publish-call recorder for tests.
actor PublishLog {
    private(set) var calls: [(doc: PresenceDocument, slug: String, repoPath: String)] = []
    func append(_ call: (PresenceDocument, String, String)) { calls.append(call) }
    var count: Int { calls.count }
}

/// Advanceable clock for heartbeat tests. @unchecked Sendable is fine here:
/// test ticks are awaited sequentially, never concurrent.
final class MutableClock: @unchecked Sendable {
    private(set) var now: Date
    init(now: Date) { self.now = now }
    func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}
