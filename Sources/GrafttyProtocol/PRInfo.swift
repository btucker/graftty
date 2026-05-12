import Foundation

public struct PRInfo: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable, Equatable {
        case open
        case merged
        /// PR/MR closed by the author or a maintainer without ever
        /// merging. `isTerminal` groups it with `.merged` for any
        /// rendering / dedup / offer-delete logic that treats "the PR
        /// is done" as a single condition (GIT-4.7, PR-8.20).
        case closed

        /// True for the terminal states `.merged` and `.closed`. Used
        /// to drive the offer-delete dialog (GIT-4.7), the badge-tone
        /// terminal-state priority (PR-8.20), the fetcher's decision
        /// to drop stale CI / mergeable signals, and the breadcrumb
        /// pill's resolved-state styling.
        public var isTerminal: Bool {
            switch self {
            case .merged, .closed: return true
            case .open:            return false
            }
        }

        /// One-word user-facing verb for a terminal PR resolution
        /// ("merged", "closed"); `nil` for `.open`. Backs the dialog
        /// title and the breadcrumb pill suffix.
        public var resolutionWord: String? {
            switch self {
            case .merged: return "merged"
            case .closed: return "closed"
            case .open:   return nil
            }
        }
    }

    public enum Checks: String, Codable, Sendable, Equatable {
        case pending
        case success
        case failure
        case none
    }

    /// Provider-reported merge state. `unknown` covers both "not yet
    /// computed" (fresh PR / GitHub still calculating) and "provider
    /// didn't return a value" — both render the same in the UI.
    /// @spec PR-8.11
    public enum Mergeable: String, Codable, Sendable, Equatable {
        case mergeable
        case conflicting
        case unknown
    }

    public let number: Int
    public let title: String
    public let url: URL
    public let state: State
    public let checks: Checks
    public let mergeable: Mergeable
    public let fetchedAt: Date

    public var id: Int { number }

    public init(
        number: Int,
        title: String,
        url: URL,
        state: State,
        checks: Checks,
        mergeable: Mergeable = .unknown,
        fetchedAt: Date
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.checks = checks
        self.mergeable = mergeable
        self.fetchedAt = fetchedAt
    }

    private enum CodingKeys: String, CodingKey {
        case number, title, url, state, checks, mergeable, fetchedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.number = try c.decode(Int.self, forKey: .number)
        self.title = try c.decode(String.self, forKey: .title)
        self.url = try c.decode(URL.self, forKey: .url)
        self.state = try c.decode(State.self, forKey: .state)
        self.checks = try c.decode(Checks.self, forKey: .checks)
        // Old persisted blobs predate this field; default to .unknown.
        self.mergeable = try c.decodeIfPresent(Mergeable.self, forKey: .mergeable) ?? .unknown
        self.fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
    }

    /// `fetchedAt` is excluded from equality so change-guards on the
    /// observable store don't trigger re-renders every poll when the
    /// semantic PR state hasn't changed.
    public static func == (lhs: PRInfo, rhs: PRInfo) -> Bool {
        lhs.number == rhs.number &&
        lhs.title == rhs.title &&
        lhs.url == rhs.url &&
        lhs.state == rhs.state &&
        lhs.checks == rhs.checks &&
        lhs.mergeable == rhs.mergeable
    }
}
