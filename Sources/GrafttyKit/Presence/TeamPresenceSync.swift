import Foundation
import Combine
import os

/// Observable store the sidebar reads: repoPath -> teammates' worktrees.
@MainActor
public final class TeamPresenceSyncStore: ObservableObject {
    @Published public private(set) var remoteWorktrees: [String: [RemoteWorktreePresence]] = [:]

    public init() {}

    func update(repoPath: String, entries: [RemoteWorktreePresence]) {
        guard remoteWorktrees[repoPath] != entries else { return }
        remoteWorktrees[repoPath] = entries
    }

    func clear(repoPath: String) {
        guard remoteWorktrees[repoPath] != nil else { return }
        remoteWorktrees.removeValue(forKey: repoPath)
    }
}

/// Periodically publishes this user's presence and fetches teammates' for
/// every repo with sharing enabled. Best-effort: a failed publish or fetch is
/// retried on the next tick; presence is ambient, never load-bearing.
@MainActor
public final class TeamPresenceSync {
    public typealias IdentityProvider = @Sendable (_ repoPath: String) async throws -> PresenceIdentity
    public typealias Publisher = @Sendable (_ doc: PresenceDocument, _ slug: String, _ repoPath: String) async throws -> Void
    public typealias Fetcher = @Sendable (_ repoPath: String) async throws -> [PresenceDocument]
    public typealias Deleter = @Sendable (_ slug: String, _ repoPath: String) async throws -> Void

    /// @spec SYNC-3.4 (behavioral spec on TeamPresenceSyncTests)
    public static let staleAfter: TimeInterval = 30 * 60
    /// @spec SYNC-3.3 (behavioral spec on TeamPresenceSyncTests)
    /// Unchanged documents are republished at this cadence so updatedAt stays
    /// ahead of teammates' staleAfter cutoff while we're alive.
    public static let heartbeatInterval: TimeInterval = 10 * 60

    private let store: TeamPresenceSyncStore
    private let identityProvider: IdentityProvider
    private let publisher: Publisher
    private let fetcher: Fetcher
    private let deleter: Deleter
    private let now: @Sendable () -> Date

    private struct LastPublish {
        let worktrees: [PresenceDocument.Worktree]
        let at: Date
    }

    private static let logger = Logger(subsystem: "com.btucker.graftty", category: "TeamPresenceSync")

    private var lastPublished: [String: LastPublish] = [:]
    /// Retained so `pulse()` can trigger an immediate tick. Assigned in
    /// `start`; the app target's `PollingTicker` outlives `startup()`.
    private var ticker: PollingTickerLike?
    /// A hung git subprocess must not stack a second tick's git work on the
    /// same refs; the next ticker fire retries.
    private var isTicking = false

    public init(
        store: TeamPresenceSyncStore,
        identityProvider: @escaping IdentityProvider = { try await PresenceIdentity.load(repoPath: $0) },
        publisher: @escaping Publisher = { try await PresenceRefSync.publish($0, slug: $1, repoPath: $2) },
        fetcher: @escaping Fetcher = { try await PresenceRefSync.fetchAll(repoPath: $0) },
        deleter: @escaping Deleter = { try await PresenceRefSync.delete(slug: $0, repoPath: $1) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.identityProvider = identityProvider
        self.publisher = publisher
        self.fetcher = fetcher
        self.deleter = deleter
        self.now = now
    }

    /// Start the polling loop with a caller-provided ticker. Uses the same
    /// ticker-injection seam as `WorktreeStatsStore.start(ticker:getRepos:)`.
    public func start(
        ticker: PollingTickerLike,
        getRepos: @escaping @MainActor () -> [RepoEntry]
    ) {
        self.ticker = ticker
        ticker.start { [weak self] in
            await self?.tick(repos: getRepos())
        }
    }

    /// Triggers an immediate tick without waiting for the polling interval
    /// (e.g. right after a repo enables sharing).
    public func pulse() {
        ticker?.pulse()
    }

    /// Tears down this user's presence for a repo after sharing is disabled:
    /// clears the local store immediately and deletes the published ref from
    /// origin. Best-effort — a failed remote delete is logged; the periodic
    /// tick keeps the local store clear regardless.
    public func leave(repoPath: String) async {
        store.clear(repoPath: repoPath)
        lastPublished.removeValue(forKey: repoPath)
        do {
            let identity = try await identityProvider(repoPath)
            try await deleter(identity.slug, repoPath)
        } catch {
            Self.logger.debug("presence ref not deleted for \(repoPath): \(error) (best-effort)")
        }
    }

    public func tick(repos: [RepoEntry]) async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        for repo in repos {
            guard repo.presenceSharingEnabled, repo.isGitTracked else {
                store.clear(repoPath: repo.path)
                lastPublished.removeValue(forKey: repo.path)
                continue
            }
            guard let identity = try? await identityProvider(repo.path) else {
                Self.logger.debug("presence sync skipped for \(repo.path): identity unavailable (set git config user.email)")
                continue
            }

            let tickNow = now()

            // Publish when the worktree set changed OR the heartbeat is due
            // (so updatedAt keeps outrunning teammates' staleness cutoff).
            let doc = PresenceDocument.build(
                user: identity.name, email: identity.email,
                worktrees: repo.worktrees, now: tickNow
            )
            let last = lastPublished[repo.path]
            let heartbeatDue = last.map { tickNow.timeIntervalSince($0.at) > Self.heartbeatInterval } ?? true
            if last?.worktrees != doc.worktrees || heartbeatDue {
                if (try? await publisher(doc, identity.slug, repo.path)) != nil {
                    lastPublished[repo.path] = LastPublish(worktrees: doc.worktrees, at: tickNow)
                }
            }

            // Fetch teammates.
            guard let docs = try? await fetcher(repo.path) else { continue }
            let cutoff = tickNow.addingTimeInterval(-Self.staleAfter)
            let ownSlug = identity.slug
            let entries: [RemoteWorktreePresence] = docs
                .filter { $0.updatedAt > cutoff }
                .flatMap { peer -> [RemoteWorktreePresence] in
                    let peerSlug = PresenceIdentity.slug(forEmail: peer.email)
                    guard peerSlug != ownSlug else { return [] }
                    return peer.worktrees.map {
                        RemoteWorktreePresence(
                            ownerName: peer.user,
                            ownerSlug: peerSlug,
                            name: $0.name, branch: $0.branch, state: $0.state,
                            updatedAt: peer.updatedAt
                        )
                    }
                }
                .sorted {
                    if $0.ownerSlug != $1.ownerSlug { return $0.ownerSlug < $1.ownerSlug }
                    return $0.name < $1.name
                }
            store.update(repoPath: repo.path, entries: entries)
        }
    }
}
