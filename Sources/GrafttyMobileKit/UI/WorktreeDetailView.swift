#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI

/// Second "inside a host" screen — shows the split-faithful tree of
/// panes for the selected worktree. Tapping a pane tile pushes a
/// `SessionStep` onto the navigation stack which opens that pane's
/// terminal fullscreen.
public struct WorktreeDetailView: View {
    public let host: Host
    public let worktree: WorktreePanes
    public let onSelectPane: (_ sessionName: String) -> Void

    public init(
        host: Host,
        worktree: WorktreePanes,
        onSelectPane: @escaping (_ sessionName: String) -> Void
    ) {
        self.host = host
        self.worktree = worktree
        self.onSelectPane = onSelectPane
    }

    public var body: some View {
        Group {
            if let layout = worktree.layout {
                PaneLayoutView(layout: layout) { sessionName in
                    onSelectPane(sessionName)
                }
            } else {
                ContentUnavailableView(
                    "No panes running",
                    systemImage: "terminal",
                    description: Text("Start a pane in Graftty on the Mac to see it here.")
                )
            }
        }
        .navigationTitle(worktree.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
