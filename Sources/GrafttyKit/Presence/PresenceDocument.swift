import Foundation

/// @spec SYNC-1.2
/// One user's published presence: the worktrees they currently have checked
/// out for a repo, as deterministic JSON (sorted keys, ISO-8601 dates).
/// Published to `refs/graftty/presence/<slug>` on the repo's origin remote;
/// the JSON travels in the commit message of an empty-tree commit.
public struct PresenceDocument: Codable, Sendable, Equatable {
    public struct Worktree: Codable, Sendable, Equatable {
        public let name: String
        public let branch: String
        /// "running" | "idle"
        public let state: String

        public init(name: String, branch: String, state: String) {
            self.name = name
            self.branch = branch
            self.state = state
        }
    }

    public let version: Int
    public let user: String
    public let email: String
    public let updatedAt: Date
    public let worktrees: [Worktree]

    public init(version: Int, user: String, email: String, updatedAt: Date, worktrees: [Worktree]) {
        self.version = version
        self.user = user
        self.email = email
        self.updatedAt = updatedAt
        self.worktrees = worktrees
    }

    /// Builds the document to publish from a repo's current worktrees.
    /// Stale and in-flight (creating/deleting) entries are excluded: stale
    /// worktrees have no on-disk checkout and in-flight ones are transient.
    public static func build(
        user: String,
        email: String,
        worktrees: [WorktreeEntry],
        now: Date
    ) -> PresenceDocument {
        let published = worktrees.compactMap { entry -> Worktree? in
            let state: String
            switch entry.state {
            case .running: state = "running"
            case .closed: state = "idle"
            case .stale, .creating, .deleting: return nil
            }
            let name = URL(fileURLWithPath: entry.path).lastPathComponent
            return Worktree(name: name, branch: entry.branch, state: state)
        }
        return PresenceDocument(
            version: 1, user: user, email: email, updatedAt: now, worktrees: published
        )
    }

    public static func encode(_ doc: PresenceDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(doc)
    }

    public static func decode(_ data: Data) throws -> PresenceDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PresenceDocument.self, from: data)
    }
}
