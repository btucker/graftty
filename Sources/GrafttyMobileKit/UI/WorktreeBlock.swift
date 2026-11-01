#if canImport(UIKit)
import GrafttyProtocol
import GrafttyCommandUI
import SwiftUI

struct WorktreeBlock: View {
    @Environment(\.editMode) private var editMode
    let worktree: WorktreePanes
    var project: SidebarProject? = nil
    var projectIconData: Data? = nil
    let theme: GhosttyThemeColors?
    /// True when this worktree's path matches `selectedWorktreePath`
    /// (IPAD-1.16). Drives both the rounded-rectangle background
    /// highlight on the whole block and the active brightness bucket
    /// for pane rows beneath it.
    let isActive: Bool
    let isOpening: Bool
    /// Session name of the focused pane within `appState`. Each pane
    /// row tests `leaf.sessionName == focusedPaneId` to decide whether
    /// to use the brightest focused bucket from `theme.paneTitle(…)`.
    let focusedPaneId: String?
    var projectColumn: Bool = false
    let context: SidebarWorktreeContext
    let onSelect: () -> Void
    let onSelectPane: (PaneLayoutNode.Leaf) -> Void
    let onReport: () -> Void

    var body: some View {
        // IPAD-1.13: pack the worktree row + its pane rows into a
        // single List row via a tight VStack so the iOS sidebar-list
        // style's default per-row padding doesn't compound between
        // panes. A small 3pt inter-row spacing gives breathing room
        // between consecutive pane rows without re-inflating to the
        // sidebar-style's full per-row padding.
        VStack(alignment: .leading, spacing: 3) {
            worktreeRow
            paneRows
            ForEach((worktree.agents ?? []).filter { $0.status == "failed" && $0.sessionName == nil }) { agent in
                Label("\(agent.name) · Failed", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        // IPAD-1.16: active-worktree block highlight (Mac parity).
        // Painted on the whole VStack so the rounded rectangle spans
        // both the worktree row and its pane children — same visual
        // grouping as the Mac sidebar's `worktreeBlock`.
        .padding(.leading, projectColumn ? 8 : 6)
        .padding(.trailing, projectColumn ? 8 : 2)
        .padding(.vertical, projectColumn ? 0 : 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlightFill)
        )
        .listRowInsets(EdgeInsets(
            top: projectColumn ? 0 : 4,
            leading: projectColumn ? 6 : WorktreeListContent.iPadRowLeadingInset,
            bottom: projectColumn ? 0 : 4,
            trailing: projectColumn ? 6 : WorktreeListContent.iPadRowTrailingInset
        ))
        .listRowSeparator(.hidden)
        .moveDisabled(editMode?.wrappedValue.isEditing != true)
    }

    /// Themed active-worktree fill when available, else `.clear`. The
    /// 0.16 alpha matches the Mac sidebar's chosen contrast on top of
    /// `theme.sidebarBackground`.
    private var highlightFill: Color {
        guard isActive else { return .clear }
        if let theme {
            return theme.foreground.opacity(0.16)
        }
        return Color.primary.opacity(0.12)
    }

    @ViewBuilder
    private var worktreeRow: some View {
        if worktree.state == .creating, worktree.showsCreationProgress {
            Button(action: onSelect) {
                HStack(spacing: 0) {
                    rowIdentity
                    DivergenceGutter(stats: worktree.stats, theme: theme)
                }
            }.buttonStyle(.plain)
        } else if worktree.state.isInFlight {
            // Non-tappable: on-disk path may not exist yet
            // (`.creating`) or is about to vanish (`.deleting`).
            HStack(spacing: 0) {
                rowIdentity
                DivergenceGutter(stats: worktree.stats, theme: theme)
            }
        } else {
            HStack(spacing: 0) {
                MobileWorktreeReportTarget(onOpen: onSelect, onReport: onReport) { rowIdentity }
                MobileWorktreeReportTarget(onOpen: onSelect, onReport: onReport) {
                    DivergenceGutter(stats: worktree.stats, theme: theme)
                        .frame(minHeight: 24)
                }
            }
            .disabled(isOpening)
        }
    }

    private var rowIdentity: some View {
        WorktreeRowContent(worktree: worktree, project: project, projectIconData: projectIconData,
            theme: theme, isActive: isActive, isOpening: isOpening,
            attentionCount: MobileWorktreeRowPresentation(context: context).worktreeAttentionCount)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var paneRows: some View {
        let presentation = MobileWorktreeRowPresentation(context: context)
        ForEach(presentation.leaves, id: \.sessionName) { leaf in
            let isQuestionPane = presentation.questionPaneID == leaf.sessionName
            let effective = leaf.attentionText
            let style = isQuestionPane ? nil : effective.map {
                AttentionCapsuleStyle.from(text: $0, source: leaf.attentionSource)
            }
            MobileWorktreeReportTarget(onOpen: onSelect, onReport: onReport) {
                VStack(alignment: .leading, spacing: 4) {
                    SidebarPaneTitleRow(title: worktree.agents?.first { $0.sessionName == leaf.sessionName }?.name ?? leaf.title,
                        isFocusedPane: false, isActiveWorktree: isActive,
                        isBusy: leaf.isBusy, attentionStyle: style,
                        attentionCount: context.pending.filter { $0.paneID == leaf.sessionName }.count,
                        theme: theme, agent: worktree.agents?.first { $0.sessionName == leaf.sessionName })
                        .padding(.leading, 18)
                    if isQuestionPane {
                        SidebarWorktreeQuestion(context: context)
                            .padding(.leading, SidebarPaneLayout.markerLeading + SidebarPaneLayout.markerSpacing)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if presentation.showsWorktreeQuestion {
            MobileWorktreeReportTarget(onOpen: onSelect, onReport: onReport) {
                SidebarWorktreeQuestion(context: context)
                    .padding(.leading, SidebarPaneLayout.markerLeading + SidebarPaneLayout.markerSpacing)
            }
        }
    }

}

/// Wrap a themed `Color` in an `AnyShapeStyle`, falling back to the
/// system `.secondary` style when no theme is supplied. Used by the row
/// helpers below so each row site doesn't re-spell the same `if let`.
private func themedOrSecondary(_ themed: Color?) -> AnyShapeStyle {
    themed.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)
}

/// Compact worktree heading with its name and forge reference on one line.
struct WorktreeRowContent: View {
    let worktree: WorktreePanes
    var project: SidebarProject? = nil
    var projectIconData: Data? = nil
    let theme: GhosttyThemeColors?
    /// True when this worktree is the active one — drives the primary
    /// label's brightness bucket via `theme.sidebarPrimaryText
    /// (isActive: …)` so the selected row reads brighter than its
    /// siblings (IPAD-1.16).
    let isActive: Bool
    let isOpening: Bool
    let attentionCount: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SidebarActivityBadge(attentionCount)
            typeIcon
            VStack(alignment: .leading, spacing: 1) {
                primaryText.accessibilityLabel(worktree.displayName)
                    .font(.system(size: 11, weight: .semibold)).tracking(0.3)
                    .lineLimit(1).truncationMode(.tail)
                if let progress = worktree.creationProgress {
                    WorktreeCreationProgressView(progress: progress)
                        .foregroundStyle(themedOrSecondary(theme?.sidebarSecondaryText))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let badge = worktree.prBadge { SidebarPRBadge(badge: badge).fixedSize() }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var typeIcon: some View {
        if worktree.state.isInFlight || isOpening {
            // Supply the title's text baseline; ProgressView's UIKit baseline
            // does not identify the center of the worktree's icon slot.
            Text(" ")
                .font(.system(size: 11, weight: .semibold))
                .hidden()
                .frame(width: 14)
                .overlay { ProgressView().controlSize(.mini) }
        } else if worktree.iconIdentity != .none {
            WorktreeIdentityView(identity: worktree.iconIdentity,
                project: project ?? SidebarProjection.projects([worktree])[0],
                imageData: projectIconData, size: 18)
        } else {
            Image(systemName: WorktreeRowIcon.symbolName(
                isMainCheckout: worktree.isMainCheckout,
                hasPR: worktree.prBadge != nil
            ))
            .font(.system(size: 11))
            .foregroundStyle(typeIconStyle)
            .frame(width: 14)
        }
    }

    /// Themed dim for closed/creating/deleting (falls back to system
    /// `.secondary` when no theme is supplied — i.e., compact iPhone
    /// path), green when running, yellow when stale. The themed path
    /// goes through the shared `GhosttyThemeColors.worktreeStateIcon`
    /// accessor so the Mac sidebar uses identical state-to-color
    /// mapping.
    private var typeIconStyle: AnyShapeStyle {
        if let theme {
            return AnyShapeStyle(theme.worktreeStateIcon(worktree.state))
        }
        // No-theme (compact iPhone) path: keep the system `.secondary`
        // dim for inactive states so the row reads against the system
        // grouped-list background.
        switch worktree.state {
        case .closed, .creating, .deleting: return AnyShapeStyle(.secondary)
        case .running: return AnyShapeStyle(Color.green)
        case .stale: return AnyShapeStyle(Color.yellow)
        }
    }

    @ViewBuilder
    private var primaryText: some View {
        let primary = theme?.sidebarPrimaryText(isActive: isActive)
        if worktree.state == .stale {
            Text(worktree.displayName.uppercased())
                .strikethrough()
                .foregroundStyle(themedOrSecondary(theme?.sidebarStaleText))
        } else if worktree.isMainCheckout {
            Text(worktree.displayName.uppercased())
                .italic()
                .foregroundColor(primary)
        } else {
            Text(worktree.displayName.uppercased())
                .foregroundColor(primary)
        }
    }


}

/// Trailing `↑X[+] ↓Y`, shared with the Mac worktree row. Without a theme
/// (compact) the ahead side stays on the system secondary color.
struct DivergenceGutter: View {
    let stats: WorktreeWireStats?
    let theme: GhosttyThemeColors?

    /// Mobile uses the sidebar's 45% secondary text (the Mac uses 55% of
    /// the foreground).
    static func aheadColor(_ theme: GhosttyThemeColors?) -> Color {
        theme?.sidebarSecondaryText ?? .secondary
    }

    var body: some View {
        if let stats, !stats.isEmpty {
            SidebarDivergenceGutter(ahead: stats.ahead, behind: stats.behind,
                hasUncommittedChanges: stats.hasUncommittedChanges,
                aheadColor: Self.aheadColor(theme))
        }
    }
}
#endif
