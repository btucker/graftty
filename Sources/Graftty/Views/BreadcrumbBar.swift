import SwiftUI
import GrafttyKit

/// The row that sits at the very top of the detail column. Shows:
/// `{repo} / {worktree-display-name} ({branch})` on the left and, when
/// available, a PR button on the trailing edge. Home checkout renders
/// as italic "root". The worktree-name carries a tooltip with the full
/// filesystem path.
struct BreadcrumbBar: View {
    let repoName: String?
    let worktreeDisplayName: String?
    let worktreePath: String?
    let branchName: String?
    let isHomeCheckout: Bool
    let prInfo: PRInfo?
    let theme: GhosttyTheme
    let sidebarHidden: Bool
    let onRefreshPR: () -> Void

    /// Leading inset wide enough to clear the three traffic-light buttons
    /// plus the sidebar-toggle button macOS parks to their right when the
    /// sidebar is collapsed, plus a hair of breathing room. Used when the
    /// breadcrumb sits at the window's left edge.
    private static let collapsedInset: CGFloat = 156

    /// Standard leading padding when the sidebar is visible — the detail
    /// column already starts past the traffic lights.
    private static let expandedInset: CGFloat = 12

    var body: some View {
        HStack(spacing: 4) {
            if let repoName {
                Text(repoName)
                    .foregroundColor(theme.foreground.opacity(0.6))
            }
            if worktreeDisplayName != nil {
                Text("/")
                    .foregroundColor(theme.foreground.opacity(0.3))
            }
            if let worktreeDisplayName {
                worktreeLabel(worktreeDisplayName)
            }
            if let branchName {
                Text("(\(branchName))")
                    .font(.caption)
                    .foregroundColor(theme.foreground.opacity(0.55))
                    .padding(.leading, 2)
            }

            Spacer()

            if let prInfo {
                PRButton(info: prInfo, theme: theme, onRefresh: onRefreshPR)
            }
        }
        .font(.callout)
        .padding(.leading, sidebarHidden ? Self.collapsedInset : Self.expandedInset)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(theme.background)
        // Animate the inset shift in lockstep with NavigationSplitView's
        // own column slide. Without this the padding flips instantly while
        // the column animates, so the breadcrumb appears to teleport.
        .animation(.easeInOut(duration: 0.25), value: sidebarHidden)
    }

    private func worktreeLabel(_ name: String) -> some View {
        Text(isHomeCheckout ? "root" : name)
            .italic(isHomeCheckout)
            .fontWeight(isHomeCheckout ? .regular : .medium)
            .foregroundColor(theme.foreground)
            .help(worktreePath ?? "")
            .overlay(underline, alignment: .bottom)
    }

    private var underline: some View {
        Rectangle()
            .fill(theme.foreground.opacity(0.3))
            .frame(height: 0.5)
            .offset(y: 1)
    }
}
