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
            .padding(.leading, 33).padding(.trailing, 8).padding(.bottom, 3)
            .contentShape(Rectangle())
    }
}

/// One sidebar worktree block: the heading button, its status line, the active
/// highlight, and the block-level drag source and drop target. The click-target
/// tests compose the same block, so hit testing covers the production structure.
struct WorktreeBlock<Heading: View, Status: View>: View {
    let worktree: WorktreeEntry
    let repoID: RepoEntry.ID
    let isActive: Bool
    let theme: GhosttyTheme
    @Binding var appState: AppState
    let reorderingEnabled: Bool
    let onSelect: () -> Void
    let menu: (NSView) -> NSMenu
    var onDrop: ((WorktreeRowDrop, WorktreeDropPlacement) -> Bool)? = nil
    @ViewBuilder let heading: () -> Heading
    @ViewBuilder let status: () -> Status

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSelect) { heading() }
                .buttonStyle(.plain)
                .id(worktree.path)
                .rightClickMenu(anchored: menu)
            status()
        }
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
    }
}
