import Foundation

/// Minimal PR snapshot consumed by the sidebar row. Narrower than
/// `PRInfo` on purpose — only the fields the sidebar badge renders —
/// so that unrelated `PRInfo` changes (checks, title, fetchedAt) do
/// not invalidate the row via SwiftUI's equality diffing.
public struct PRBadge: Equatable, Sendable {
    public let number: Int
    public let state: PRInfo.State
    public let url: URL

    public init(number: Int, state: PRInfo.State, url: URL) {
        self.number = number
        self.state = state
        self.url = url
    }
}
