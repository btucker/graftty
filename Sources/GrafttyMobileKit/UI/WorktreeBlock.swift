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
    /// for its text.
    let isActive: Bool
    let isOpening: Bool
    var projectColumn: Bool = false
    let context: SidebarWorktreeContext
    let onSelect: () -> Void
    /// A row from a sleeping host's last report: dim, and tapping wakes it.
    var isCached = false
    /// Text after the name: see `SidebarMergedRows.hostText`. The Projects
    /// screen also names the project here.
    var hostText: String? = nil
    /// Where this row belongs, on a list that mixes projects. Drawn on its own
    /// line, so a long worktree name can't push it out.
    var eyebrow: String? = nil
    let onReport: () -> Void
    var onRemove: (() -> Void)? = nil
    /// Hides the row's current request on this device (LAYOUT-2.216).
    var onDismissRequest: () -> Void = {}

    var body: some View {
        // IPAD-1.13: pack the worktree row + its status line into a
        // single List row, so the iOS sidebar-list style's default per-row
        // padding doesn't compound between them.
        SidebarWorktreeRowLayout {
            identity
        } content: {
            if let eyebrow {
                Text(eyebrow).font(.caption2)
                    .foregroundStyle(themedOrSecondary(theme?.sidebarSecondaryText))
                    .lineLimit(1)
            }
            worktreeRow
            statusLine
            ForEach((worktree.agents ?? []).filter { $0.status == "failed" && $0.sessionName == nil }) { agent in
                Label("\(agent.name) · Failed", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        // IPAD-1.16: active-worktree block highlight (Mac parity).
        // Painted on the whole VStack so the rounded rectangle spans
        // both the worktree row and its status line — same visual
        // grouping as the Mac sidebar's `worktreeBlock`.
        .padding(.leading, projectColumn ? 8 : 6)
        .padding(.trailing, projectColumn ? 8 : 2)
        .padding(.vertical, 5)
        .frame(minHeight: 44)
        .opacity(isCached ? 0.55 : 1)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlightFill)
        )
        .contextMenu {
            if !worktree.state.isInFlight {
                MobileWorktreeRowMenu(context: context, onReport: onReport, onDismiss: onDismissRequest)
            }
        }
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
                rowIdentity
            }.buttonStyle(.plain)
        } else if worktree.state.isInFlight {
            // Non-tappable: on-disk path may not exist yet
            // (`.creating`) or is about to vanish (`.deleting`).
            rowIdentity
        } else {
            HStack(spacing: 0) {
                MobileWorktreeReportTarget(onOpen: onSelect, onReport: onReport) { rowIdentity }
                if let onRemove, SidebarMergedWorktreeRemoval.isAvailable(
                    prState: worktree.prBadge?.state, isMainCheckout: worktree.isMainCheckout, state: worktree.state) {
                    // A 44-point target that takes only the heading's height, so the
                    // row doesn't grow (IOS-13.18); taps above and below still reach it.
                    Button(action: onRemove) {
                        Image(systemName: "trash").frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.borderless)
                        .padding(.vertical, -10)
                        .foregroundStyle(theme?.sidebarSecondaryText ?? .secondary)
                        .accessibilityLabel("Remove worktree \(worktree.displayName)")
                }
            }
            .disabled(isOpening)
        }
    }

    private var rowIdentity: some View {
        WorktreeRowContent(worktree: worktree, project: project, projectIconData: projectIconData,
            theme: theme, isActive: isActive, isOpening: isOpening,
            hostText: hostText,
            time: WorktreeActivitySections.rowDate(worktree, context: context))
            .frame(minHeight: 24)
            .contentShape(Rectangle())
    }

    private var identity: some View {
        WorktreeBlockIdentity(worktree: worktree, project: project, projectIconData: projectIconData,
                              theme: theme, status: status, isOpening: isOpening)
    }

    private var status: SidebarRowStatus {
        SidebarRowStatus.resolve(context: context, worktree: worktree, isCached: isCached)
    }

    @ViewBuilder
    private var statusLine: some View {
        if status != .none {
            MobileWorktreeReportTarget(onOpen: onSelect, onReport: onReport) {
                SidebarStatusLine(status: status, secondary: theme?.sidebarSecondaryText ?? .secondary)
            }
        }
    }
}

/// A row's emoji, image or type icon. While the row is creating, deleting or
/// opening, a spinner takes its place, level with the name, so the name never
/// moves (IOS-9.16).
struct WorktreeBlockIdentity: View {
    let worktree: WorktreePanes
    let project: SidebarProject?
    let projectIconData: Data?
    let theme: GhosttyThemeColors?
    let status: SidebarRowStatus
    let isOpening: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if worktree.state.isInFlight || isOpening {
            // A blank line of the title's font, padded like the title, centres
            // the spinner on the name's line.
            Text(" ")
                .font(.system(size: WorktreeRowContent.titleSize(for: sizeClass), weight: .semibold))
                .hidden()
                .frame(maxWidth: .infinity)
                .overlay { ProgressView().controlSize(.mini) }
                .padding(.vertical, WorktreeRowContent.verticalPadding)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if worktree.iconIdentity != .none {
            SidebarWorktreeRowIdentity(identity: worktree.iconIdentity,
                project: project ?? SidebarProjection.projects([worktree])[0],
                imageData: projectIconData, status: status)
        } else {
            Image(systemName: WorktreeRowIcon.symbolName(isMainCheckout: worktree.isMainCheckout, hasPR: worktree.prBadge != nil))
                .font(.system(size: 16))
                .foregroundStyle(WorktreeRowContent.stateStyle(worktree.state, theme: theme))
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
/// @spec IOS-13.12: While a mobile worktree list shows a row, the application shall show its name in its own letter case, followed by its PR number when it has one and its time at the trailing edge.
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
    var hostText: String? = nil
    /// When it asked or was last active.
    var time: Date? = nil

    @Environment(\.horizontalSizeClass) private var sizeClass

    /// IPAD-1.35: the iPad sidebar is narrow beside the terminal, so names
    /// are smaller there than on a phone's full-width list.
    static func titleSize(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? 13 : 15
    }
    static let verticalPadding: CGFloat = 4

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    primaryText
                        .font(.system(size: Self.titleSize(for: sizeClass), weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                    if let hostText {
                        Text(hostText)
                            .font(.caption)
                            .foregroundStyle(themedOrSecondary(theme?.sidebarSecondaryText))
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
                if let progress = worktree.creationProgress {
                    WorktreeCreationProgressView(progress: progress)
                        .foregroundStyle(themedOrSecondary(theme?.sidebarSecondaryText))
                }
            }
            if let badge = worktree.prBadge { SidebarPRBadge(badge: badge).fixedSize() }
            Spacer(minLength: 0)
            if let time {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    Text(WorktreeActivitySections.ageText(since: time, now: timeline.date))
                        .font(.caption)
                        .foregroundStyle(themedOrSecondary(theme?.sidebarSecondaryText))
                        .accessibilityLabel(time.formatted(.relative(presentation: .named)))
                }
                .fixedSize()
            }
        }
        .padding(.vertical, Self.verticalPadding)
        .contentShape(Rectangle())
    }

    /// Themed dim for closed/creating/deleting (falls back to system
    /// `.secondary` when no theme is supplied — i.e., compact iPhone
    /// path), green when running, yellow when stale. The themed path
    /// goes through the shared `GhosttyThemeColors.worktreeStateIcon`
    /// accessor so the Mac sidebar uses identical state-to-color
    /// mapping.
    static func stateStyle(_ state: WorktreeWireState, theme: GhosttyThemeColors?) -> AnyShapeStyle {
        if let theme {
            return AnyShapeStyle(theme.worktreeStateIcon(state))
        }
        // No-theme (compact iPhone) path: keep the system `.secondary`
        // dim for inactive states so the row reads against the system
        // grouped-list background.
        switch state {
        case .closed, .creating, .deleting: return AnyShapeStyle(.secondary)
        case .running: return AnyShapeStyle(Color.green)
        case .stale: return AnyShapeStyle(Color.yellow)
        }
    }

    @ViewBuilder
    private var primaryText: some View {
        let primary = theme?.sidebarPrimaryText(isActive: isActive)
        if worktree.state == .stale {
            Text(worktree.displayName)
                .strikethrough()
                .foregroundStyle(themedOrSecondary(theme?.sidebarStaleText))
        } else if worktree.isMainCheckout {
            Text(worktree.displayName)
                .italic()
                .foregroundColor(primary)
        } else {
            Text(worktree.displayName)
                .foregroundColor(primary)
        }
    }


}

/// `↑X[+] ↓Y`, shared with the Mac worktree row. Without a theme
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
                aheadColor: Self.aheadColor(theme), behindColor: (theme?.foreground ?? .primary).opacity(0.75))
        }
    }
}
#endif
