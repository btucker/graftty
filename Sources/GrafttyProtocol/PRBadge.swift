import Foundation

/// Minimal PR snapshot consumed by sidebar-style worktree rows on Mac
/// and iOS. Narrower than `PRInfo` on purpose — only the fields the
/// row badge renders — so that unrelated `PRInfo` changes (title,
/// fetchedAt) do not invalidate the row via SwiftUI's equality
/// diffing. `checks` and `mergeable` are included because the
/// `#<number>` color reflects CI state (`PR-3.5`) and merge-conflict
/// state (`PR-8.20`), so a transition in either must invalidate the
/// row.
///
/// `Codable` so it can travel on the wire to mobile clients via
/// `GET /worktrees/panes`.
public struct PRBadge: Codable, Equatable, Sendable, Hashable {
    public let number: Int
    public let state: PRInfo.State
    public let checks: PRInfo.Checks
    public let mergeable: PRInfo.Mergeable
    public let url: URL

    public init(
        number: Int,
        state: PRInfo.State,
        checks: PRInfo.Checks,
        mergeable: PRInfo.Mergeable = .unknown,
        url: URL
    ) {
        self.number = number
        self.state = state
        self.checks = checks
        self.mergeable = mergeable
        self.url = url
    }

    /// Project the row-relevant fields out of a full `PRInfo`.
    public init(from info: PRInfo) {
        self.init(
            number: info.number,
            state: info.state,
            checks: info.checks,
            mergeable: info.mergeable,
            url: info.url
        )
    }
}
