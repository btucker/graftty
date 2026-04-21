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
    let onRefreshPR: () -> Void

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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.background)
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
