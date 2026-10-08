import AppKit
import SwiftUI
import GrafttyKit

/// One sidebar worktree block: the heading button, the pane rows beneath
/// it, the unified active highlight and drop stroke, and the block-level
/// drag source / drop target. `SidebarView` supplies the heading and pane
/// content; the click-target tests compose the same block so hit testing
/// is verified against the production structure rather than a copy.
struct WorktreeBlock<Heading: View, Panes: View>: View {
    let worktree: WorktreeEntry
    let repoID: RepoEntry.ID
    let isActive: Bool
    let isDropTarget: Bool
    /// True when pane rows render under the heading on the project column.
    /// The block then carries vertical breathing room inside its highlight.
    let groupsPanes: Bool
    let theme: GhosttyTheme
    @Binding var appState: AppState
    let reorderingEnabled: Bool
    let onSelect: () -> Void
    let onMovePane: (PaneSlotID, String) -> Void
    let onPaneTargeted: (Bool) -> Void
    let menu: (NSView) -> NSMenu
    @ViewBuilder let heading: () -> Heading
    @ViewBuilder let panes: () -> Panes

    var body: some View {
        VStack(spacing: 0) {
            if groupsPanes { breathingRoom }
            Button(action: onSelect) { heading() }
                .buttonStyle(.plain)
                .id(worktree.path)
                .transformAnchorPreference(key: WorktreeHeadingAnchor.self, value: .bounds) { $0[.heading] = $1 }
                .rightClickMenu(anchored: menu)

            panes()
            if groupsPanes { breathingRoom }
        }
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? theme.highlightedWorktreeBackground : .clear)
        )
        // PWD-1.5: drop-target highlight. Stroked so it composes with
        // the active-worktree background fill above when the dragged-
        // onto row is also the active one.
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.foreground.opacity(isDropTarget ? 0.5 : 0), lineWidth: 1.5)
        )
        // The whole block (heading + pane rows) is the drag image and the
        // drop target, so a worktree never lands between another's panes.
        .worktreeReorderTarget(
            repoID: repoID,
            worktreeID: worktree.id,
            appState: $appState, isEnabled: reorderingEnabled,
            onSelect: onSelect,
            onMovePane: onMovePane,
            onPaneTargeted: onPaneTargeted
        )
    }

    /// LAYOUT-2.117: the native block target also selects through this space.
    private var breathingRoom: some View {
        Color.clear.frame(maxWidth: .infinity).frame(height: 8)
            .accessibilityHidden(true)
    }
}
