import SwiftUI

/// Pinned tiles and the New worktree line stay put above the list, at the
/// height they need. The list below takes the rest and scrolls.
struct SidebarWorktreeViewport<Pinned: View, Controls: View, Content: View>: View {
    @ViewBuilder var pinned: () -> Pinned
    @ViewBuilder var controls: () -> Controls
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            pinned().fixedSize(horizontal: false, vertical: true)
            controls().fixedSize(horizontal: false, vertical: true)
            content().frame(maxHeight: .infinity)
        }
    }
}
