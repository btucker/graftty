import GrafttyCommandUI
import SwiftUI

struct SidebarWorktreeDivider: View {
    static var thickness: CGFloat { HorizontalResizeDivider.thickness }
    var onResize: (CGFloat) -> Void
    var onResizeEnd: () -> Void

    var body: some View {
        HorizontalResizeDivider(label: "Resize pinned agents", separatorIdentifier: "Worktree list divider",
            onResize: onResize, onResizeEnd: onResizeEnd)
    }
}
