import AppKit
import SwiftUI
import GrafttyKit
import GrafttyCommandUI

/// The question owns its click so the block's drag target cannot replace
/// navigation to the requesting pane with worktree-only selection.
struct SidebarWorktreeStatusTarget: View {
    let status: SidebarRowStatus
    let secondary: Color
    let onOpen: () -> Void

    var body: some View {
        if status == .none {
            EmptyView()
        } else if status.opensPane {
            Button(action: onOpen) { line }
                .buttonStyle(.plain)
                .accessibilityHint("Open the worktree and focus the requesting pane")
                .anchorPreference(key: WorktreeControlAnchors.self, value: .bounds) { [.question: $0] }
        } else {
            line
        }
    }

    private var line: some View {
        SidebarStatusLine(status: status, secondary: secondary)
            .padding(.top, SidebarStatusLine.macTopInset)
            .padding(.trailing, 8).padding(.bottom, SidebarStatusLine.macBottomInset(status))
            .contentShape(Rectangle())
    }
}

/// One sidebar worktree block: the heading button, its status line, the active
/// highlight, and the block-level drag source and drop target. The click-target
/// tests compose the same block, so hit testing covers the production structure.
struct WorktreeBlock<Identity: View, Heading: View, Status: View>: View {
    let worktree: WorktreeEntry
    let repoID: RepoEntry.ID
    let isActive: Bool
    let theme: GhosttyTheme
    @Binding var appState: AppState
    let reorderingEnabled: Bool
    let onSelect: () -> Void
    let menu: (NSView) -> NSMenu
    var onDrop: ((WorktreeRowDrop, WorktreeDropPlacement) -> Bool)? = nil
    @ViewBuilder var identity: () -> Identity
    @ViewBuilder let heading: () -> Heading
    @ViewBuilder let status: () -> Status

    var body: some View {
        SidebarWorktreeRowLayout {
            Button(action: onSelect) { identity().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                // Fills the identity column, so an emoji's own, smaller menu stays innermost.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .rightClickMenu(anchored: menu)
        } content: {
            Button(action: onSelect) { heading() }
                .buttonStyle(.plain)
                .id(worktree.path)
                .rightClickMenu(anchored: menu)
            status().rightClickMenu(anchored: menu)
        }
        .padding(.leading, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? theme.highlightedWorktreeBackground : .clear)
        )
        .worktreeReorderTarget(
            repoID: repoID,
            worktreeID: worktree.id,
            appState: $appState, isEnabled: reorderingEnabled,
            onSelect: onSelect, onDrop: onDrop
        )
        .padding(.vertical, SidebarWorktreeListStyle.macRowOuterInset)
    }
}

extension WorktreeBlock where Identity == EmptyView {
    /// A block whose row has no identity to draw.
    init(worktree: WorktreeEntry, repoID: RepoEntry.ID, isActive: Bool, theme: GhosttyTheme, appState: Binding<AppState>,
         reorderingEnabled: Bool, onSelect: @escaping () -> Void, menu: @escaping (NSView) -> NSMenu,
         onDrop: ((WorktreeRowDrop, WorktreeDropPlacement) -> Bool)? = nil,
         @ViewBuilder heading: @escaping () -> Heading, @ViewBuilder status: @escaping () -> Status) {
        self.init(worktree: worktree, repoID: repoID, isActive: isActive, theme: theme, appState: appState,
                  reorderingEnabled: reorderingEnabled, onSelect: onSelect, menu: menu, onDrop: onDrop,
                  identity: { EmptyView() }, heading: heading, status: status)
    }
}
