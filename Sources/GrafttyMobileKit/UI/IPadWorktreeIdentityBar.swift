#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

/// The worktree's one-line purpose under the toolbar, on the emoji wash.
struct IPadWorktreePurposeLine: View {
    let worktree: WorktreePanes
    let context: SidebarWorktreeContext
    let theme: GhosttyThemeColors

    var body: some View {
        let purpose = MobileWorktreeOverview(worktree: worktree, context: context).purpose
        if purpose != nil || worktree.prBadge != nil {
            HStack(spacing: 8) {
                if let badge = worktree.prBadge { SidebarPRBadge(badge: badge) }
                if let purpose {
                    Text(purpose).font(.subheadline).foregroundStyle(theme.foreground.opacity(0.78)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 6)
        }
    }
}
#endif
