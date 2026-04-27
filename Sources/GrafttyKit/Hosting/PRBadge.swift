import Foundation

/// Minimal PR snapshot consumed by the sidebar row. Narrower than
/// `PRInfo` on purpose — only the fields the sidebar badge renders —
/// so that unrelated `PRInfo` changes (title, fetchedAt) do not
/// invalidate the row via SwiftUI's equality diffing. `checks` *is*
/// included because the sidebar `#<number>` color reflects CI state
/// per `PR-3.5` (red on failure, pulsing orange on pending), so a
/// CI transition must invalidate the row.
public struct PRBadge: Equatable, Sendable {
    public let number: Int
    public let state: PRInfo.State
    public let checks: PRInfo.Checks
    public let url: URL

    public init(number: Int, state: PRInfo.State, checks: PRInfo.Checks, url: URL) {
        self.number = number
        self.state = state
        self.checks = checks
        self.url = url
    }
}
