#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI

/// @spec IPAD-1.24: While the iPad layout displays a paired host, the application shall apply the host's pushed panes-state frames to the shared worktree state from outside the split view's columns, so the collapsed-sidebar attention indicator (IPAD-1.11) stays current without the sidebar list on screen.
struct IPadWorktreeFeed: ViewModifier {
    let hostID: UUID?
    let feed: MultiHostFeed?
    let appState: IPadAppState
    /// Runs after each applied frame, for the layout's pending pane mutations.
    let didApply: @MainActor ([WorktreePanes]) -> Void

    private var rows: [WorktreePanes]? {
        // Keep the last rows while the selected host is unreachable.
        guard let hostID, let feed, feed.state.isLive(hostID) else { return nil }
        return feed.state.rawRows(of: hostID)
    }

    func body(content: Content) -> some View {
        content.onChange(of: rows, initial: true) { _, list in
            guard let list else { return }
            IPadRootLayout.onWorktreeListChanged(appState: appState, list: list)
            didApply(list)
        }
    }
}
#endif
