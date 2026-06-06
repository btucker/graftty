import Foundation
import Combine

/// One teammate worktree as rendered in the sidebar.
public struct RemoteWorktreePresence: Sendable, Equatable, Identifiable {
    public let ownerName: String
    public let ownerSlug: String
    public let name: String
    public let branch: String
    public let state: PresenceDocument.Worktree.State
    public let updatedAt: Date

    public var id: String { "\(ownerSlug)/\(name)" }

    public init(
        ownerName: String,
        ownerSlug: String,
        name: String,
        branch: String,
        state: PresenceDocument.Worktree.State,
        updatedAt: Date
    ) {
        self.ownerName = ownerName
        self.ownerSlug = ownerSlug
        self.name = name
        self.branch = branch
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// Observable store the sidebar reads: repoPath -> teammates' worktrees.
@MainActor
public final class TeamPresenceSyncStore: ObservableObject {
    @Published public private(set) var remoteWorktrees: [String: [RemoteWorktreePresence]] = [:]

    public init() {}

    func update(repoPath: String, entries: [RemoteWorktreePresence]) {
        remoteWorktrees[repoPath] = entries
    }

    func clear(repoPath: String) {
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
    private let now: @Sendable () -> Date

    private struct LastPublish {
        let worktrees: [PresenceDocument.Worktree]
        let at: Date
    }

    private var lastPublished: [String: LastPublish] = [:]

    public init(
        store: TeamPresenceSyncStore,
        identityProvider: @escaping IdentityProvider = { try await PresenceIdentity.load(repoPath: $0) },
        publisher: @escaping Publisher = { try await PresenceRefSync.publish($0, slug: $1, repoPath: $2) },
        fetcher: @escaping Fetcher = { try await PresenceRefSync.fetchAll(repoPath: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.identityProvider = identityProvider
        self.publisher = publisher
        self.fetcher = fetcher
        self.now = now
    }

    /// Start the polling loop with a caller-provided ticker. Mirrors
    /// `WorktreeStatsStore.start(ticker:getRepos:)`.
    public func start(
        ticker: PollingTickerLike,
        getRepos: @escaping @MainActor () -> [RepoEntry]
    ) {
        ticker.start { [weak self] in
            await self?.tick(repos: getRepos())
        }
    }

    public func tick(repos: [RepoEntry]) async {
        for repo in repos {
            guard repo.presenceSharingEnabled, repo.isGitTracked else {
                store.clear(repoPath: repo.path)
                lastPublished.removeValue(forKey: repo.path)
                continue
            }
            guard let identity = try? await identityProvider(repo.path) else { continue }

            // Publish when the worktree set changed OR the heartbeat is due
            // (so updatedAt keeps outrunning teammates' staleness cutoff).
            let doc = PresenceDocument.build(
                user: identity.name, email: identity.email,
                worktrees: repo.worktrees, now: now()
            )
            let last = lastPublished[repo.path]
            let heartbeatDue = last.map { now().timeIntervalSince($0.at) > Self.heartbeatInterval } ?? true
            if last?.worktrees != doc.worktrees || heartbeatDue {
                if (try? await publisher(doc, identity.slug, repo.path)) != nil {
                    lastPublished[repo.path] = LastPublish(worktrees: doc.worktrees, at: now())
                }
            }

            // Fetch teammates.
            guard let docs = try? await fetcher(repo.path) else { continue }
            let cutoff = now().addingTimeInterval(-Self.staleAfter)
            let ownSlug = identity.slug
            let entries: [RemoteWorktreePresence] = docs
                .filter { PresenceIdentity.slug(forEmail: $0.email) != ownSlug }
                .filter { $0.updatedAt > cutoff }
                .flatMap { peer in
                    peer.worktrees.map {
                        RemoteWorktreePresence(
                            ownerName: peer.user,
                            ownerSlug: PresenceIdentity.slug(forEmail: peer.email),
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
