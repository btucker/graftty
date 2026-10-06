import SwiftUI
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

/// Worktree visit navigation, recent-worktree menu, and the current PR.
/// The selected worktree's effective identity appears before its name.
struct BreadcrumbBar: View {
    let repoName: String?
    let worktreeDisplayName: String?
    let worktreeEmoji: String?
    let worktreePath: String?
    let branchName: String?
    let isHomeCheckout: Bool
    let prInfo: PRInfo?
    let theme: GhosttyTheme
    let sidebarHidden: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let historyItems: [BreadcrumbHistoryItem]
    let currentTarget: WorktreeNavigationTarget?
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onSelectHistory: (WorktreeNavigationTarget) -> Void
    let onRefreshPR: () -> Void
    var project: SidebarProject? = nil
    var projectIconData: Data? = nil
    @State private var showsHistory = false

    /// Leading inset wide enough to clear the three traffic-light buttons
    /// plus the sidebar-toggle button macOS parks to their right when the
    /// sidebar is collapsed, plus a hair of breathing room. Used when the
    /// breadcrumb sits at the window's left edge.
    private static let collapsedInset: CGFloat = 156

    /// Standard leading padding when the sidebar is visible — the detail
    /// column already starts past the traffic lights.
    private static let expandedInset: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                navigationButton("chevron.left", title: "Back", enabled: canGoBack, action: onGoBack)
                navigationButton("chevron.right", title: "Forward", enabled: canGoForward, action: onGoForward)
            }

            Button {
                showsHistory.toggle()
            } label: {
                HStack(spacing: 4) {
                    breadcrumbLabel
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.foreground.opacity(0.55))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(historyItems.isEmpty)
            .accessibilityLabel("Recent worktrees")
            .accessibilityValue(currentLocationAccessibilityValue)
            .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
                historyDropdown
            }

            Spacer(minLength: 8)

            if let prInfo {
                PRButton(info: prInfo, theme: theme, onRefresh: onRefreshPR)
            }
        }
        .font(.callout)
        .padding(.leading, sidebarHidden ? Self.collapsedInset : Self.expandedInset)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(theme.background)
        // Follow NavigationSplitView's column slide.
        .animation(.easeInOut(duration: 0.25), value: sidebarHidden)
    }

    var currentLocationAccessibilityValue: String {
        [repoName, worktreeDisplayName, branchName.map { "Branch \($0)" }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private var historyDropdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Worktrees")
                .font(.caption)
                .foregroundColor(theme.foreground.opacity(0.6))
                .padding(.horizontal, 8)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(historyItems) { item in
                        Button {
                            showsHistory = false
                            onSelectHistory(item.target)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark")
                                    .opacity(item.target == currentTarget ? 1 : 0)
                                    .frame(width: 12)
                                Text(item.menuTitle)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .font(.callout)
                            .foregroundColor(theme.foreground)
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(item.path)
                        .accessibilityValue(item.target == currentTarget ? "Current worktree" : "")
                    }
                }
            }
            .frame(height: min(CGFloat(historyItems.count) * 34, 320))
        }
        .padding(8)
        .frame(width: 460)
        .background(theme.background)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private func navigationButton(_ symbol: String, title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.foreground.opacity(enabled ? 0.8 : 0.25))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
    }

    private var breadcrumbLabel: some View {
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
                WorktreeIdentityView(identity: iconIdentity,
                    project: project ?? SidebarProject(id: worktreePath ?? "", repositoryID: worktreePath ?? "", name: repoName ?? ""),
                    imageData: projectIconData, size: 18)
                worktreeLabel(worktreeDisplayName)
            }
            if let branchName {
                Text("(\(branchName))")
                    .font(.caption)
                    .foregroundColor(theme.foreground.opacity(0.55))
                    .padding(.leading, 2)
            }

            if repoName == nil && worktreeDisplayName == nil {
                Text("Recent Worktrees")
                    .foregroundColor(theme.foreground.opacity(0.6))
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    var iconIdentity: WorktreeIconIdentity {
        .resolve(isMainCheckout: isHomeCheckout, emoji: worktreeEmoji)
    }

    static func selectedWorktreeEmoji(localEmoji: String?, remoteWorktree: WorktreePanes?) -> String? {
        if let remoteWorktree { return remoteWorktree.effectiveEmoji }
        return localEmoji
    }

    private func worktreeLabel(_ name: String) -> some View {
        Text(name)
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
