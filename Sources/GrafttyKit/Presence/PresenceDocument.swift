import Foundation

/// @spec SYNC-1.2
/// One user's published presence: the worktrees they currently have checked
/// out for a repo, as deterministic JSON (sorted keys, ISO-8601 dates).
/// Published to `refs/graftty/presence/<slug>` on the repo's origin remote;
/// the JSON travels in the commit message of an empty-tree commit.
public struct PresenceDocument: Codable, Sendable, Equatable {
    public struct Worktree: Codable, Sendable, Equatable {
        /// Wire state of a worktree in a presence document.
        ///
        /// Decoding a document that contains an unknown state value fails the
        /// whole document decode; callers treat an undecodable document as
        /// "skip this peer's doc" — acceptable v1 forward-compatibility.
        /// Version bumps cover format evolution.
        public enum State: String, Codable, Sendable {
            case running
            case idle
        }

        public let name: String
        public let branch: String
        public let state: State

        public init(name: String, branch: String, state: State) {
            self.name = name
            self.branch = branch
            self.state = state
        }
    }

    /// Format version (currently 1). Not validated on decode: fetch-side
    /// callers skip undecodable documents, which covers incompatible futures.
    public let version: Int
    /// Display name sourced from git user.name.
    public let user: String
    /// Keys the publisher's ref slug (refs/graftty/presence/<slug>).
    public let email: String
    /// Wall-clock snapshot time; used as the staleness cutoff input.
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
            let state: Worktree.State
            switch entry.state {
            case .running: state = .running
            case .closed: state = .idle
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
