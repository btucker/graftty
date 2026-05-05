import SwiftUI
import GrafttyKit

/// Public entry point for one row in the Team Activity Log. Takes a
/// fully-resolved `RenderedFeedItem` and dispatches to the right
/// component (TranscriptRow for chat / system, CenteredMarkerRow for
/// member-joined / member-left, DayDividerRow for day boundaries).
struct TeamActivityLogRow: View {
    let item: RenderedFeedItem

    var body: some View {
        switch item.row {
        case .chat, .system:
            TranscriptRow(row: item.row, isContinuation: item.isContinuation)
        case let .memberJoined(worktree):
            CenteredMarkerRow(kind: .joined(worktree: worktree))
        case let .memberLeft(worktree):
            CenteredMarkerRow(kind: .left(worktree: worktree))
        case let .dayDivider(label):
            DayDividerRow(label: label)
        }
    }
}
