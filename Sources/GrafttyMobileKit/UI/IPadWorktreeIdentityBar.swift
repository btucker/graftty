#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

/// The worktree's one-line purpose under the toolbar, on the emoji wash.
struct IPadWorktreePurposeLine: View {
    let worktree: WorktreePanes
    let context: SidebarWorktreeContext
    let theme: GhosttyThemeColors
    var usesNavigationSubtitle = false

    var body: some View {
        let purpose = MobileWorktreeOverview(worktree: worktree, context: context).purpose
        if usesNavigationSubtitle {
            Color.clear.frame(height: 0)
        } else if purpose != nil || worktree.prBadge != nil {
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

/// IPAD-1.31: the PR and summary as the navigation title's subtitle, which
/// iPadOS 26 draws inside the toolbar instead of a separate row.
struct IPadWorktreeSubtitle: ViewModifier {
    let text: String?

    static var isAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    static func text(for worktree: WorktreePanes, context: SidebarWorktreeContext) -> String? {
        let parts = [worktree.prBadge.map { "#\($0.number)" },
                     MobileWorktreeOverview(worktree: worktree, context: context).purpose].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), let text {
            content.navigationSubtitle(text)
        } else {
            content
        }
    }
}
#endif
