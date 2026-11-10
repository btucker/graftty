import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

private enum WorktreeRowGeometry {
    static let spacing: CGFloat = 6
    static let horizontalInset: CGFloat = 8
}

struct WorktreeRow: View {
    let entry: WorktreeEntry
    /// True when this is the currently-selected worktree. Used only for
    /// *text* emphasis; the row's highlight background is drawn by the
    /// enclosing worktree block in SidebarView, which spans both this row
    /// and its status line.
    let isActive: Bool
    /// Primary display label, computed by the sidebar with knowledge of
    /// the worktree's siblings so we can disambiguate same-basename
    /// worktrees.
    let displayName: String
    /// True if this is the repo's main checkout (path == repo.path).
    /// Gets a distinct leading icon to differentiate from linked worktrees.
    let isMainCheckout: Bool
    /// Theme snapshot for foreground/dim text colors, so the sidebar
    /// matches ghostty's palette rather than fighting it.
    let theme: GhosttyTheme
    /// Divergence stats for this worktree, or nil when unresolved (no
    /// origin remote, stale, not yet computed).
    let stats: WorktreeStats?
    /// The base ref the divergence stats were measured against. Used in
    /// the tooltip so the user knows what the numbers mean (e.g.
    /// `"origin/main"` for the main checkout, `"main"` for a linked
    /// worktree). Nil when the default branch isn't resolvable.
    let baseRef: String?
    /// Narrow PR snapshot for this worktree, or nil when no PR/MR is
    /// associated. Drives (a) the fallback leading-icon swap to the
    /// pull-request glyph (PR-3.1) and (b) the colored forge reference badge
    /// between the leading identity and worktree label (PR-3.2, PR-3.3). `PRBadge` is
    /// deliberately narrower than `PRInfo` so unrelated changes (CI
    /// checks, title, fetchedAt) don't invalidate the row on each poll.
    let prBadge: PRBadge?
    /// Set when the host matters for this row: see `MergedWorktreeRow.showsHostLabel`.
    var hostLabel: String? = nil
    var brief: WorktreeBrief? = nil
    var onRemove: ((NSWindow) -> Void)? = nil
    /// False when the divergence goes on the status line instead (DIVERGE-1.1).
    var showsDivergence = true

    enum LeadingItem: Hashable {
        case projectIcon, emoji, typeIcon, prBadge, label
    }

    static func leadingSequence(isMainCheckout: Bool = false, hasEmoji: Bool, hasPR: Bool,
                                isInFlight: Bool = false) -> [LeadingItem] {
        let identity: LeadingItem = isInFlight ? .typeIcon : isMainCheckout ? .projectIcon : hasEmoji ? .emoji : .typeIcon
        var items: [LeadingItem] = [identity, .label]
        if hasPR { items.append(.prBadge) }
        return items
    }

    enum TrailingItem: Hashable { case removeButton, divergence }

    /// @spec DIVERGE-1.1
    /// The name line ends with the PR/MR badge, and the divergence sits
    /// right-aligned on the status line beneath it. A merged worktree's
    /// remove button takes the divergence's place, on the name line.
    static func trailingItems(canRemove: Bool) -> (nameLine: [TrailingItem], statusLine: [TrailingItem]) {
        canRemove ? ([.removeButton], []) : ([], [.divergence])
    }

    var canRemove: Bool {
        onRemove != nil && SidebarMergedWorktreeRemoval.isAvailable(
            prState: prBadge?.state, isMainCheckout: isMainCheckout, state: entry.state.wireState)
    }

    var body: some View {
        HStack(spacing: WorktreeRowGeometry.spacing) {
            ForEach(Self.leadingSequence(isMainCheckout: isMainCheckout, hasEmoji: entry.emoji != nil, hasPR: prBadge != nil,
                                         isInFlight: entry.state.isInFlight), id: \.self) { item in
                switch item {
                case .projectIcon, .emoji, .typeIcon:
                    EmptyView() // Drawn beside the row by `WorktreeRowIdentitySlot`.
                case .prBadge:
                    if let prBadge {
                        SidebarPRBadge(badge: prBadge)
                            .fixedSize(horizontal: true, vertical: false)
                            .anchorPreference(key: WorktreeControlAnchors.self, value: .bounds) { [.prBadge: $0] }
                    }
                case .label:
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            branchLabel
                            if let hostLabel {
                                Text(hostLabel)
                                    .font(.system(size: 10.5))
                                    .foregroundColor(theme.sidebarDimIcon)
                                    .lineLimit(1)
                                    .layoutPriority(-1)
                            }
                        }
                        if let progress = entry.creationProgress {
                            WorktreeCreationProgressView(progress: progress)
                                .foregroundStyle(theme.sidebarSecondaryText)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)

                }
            }
            if let onRemove, Self.trailingItems(canRemove: canRemove).nameLine.contains(.removeButton) {
                SidebarRemoveWorktreeButton(name: displayName, color: theme.sidebarSecondaryText, onRemove: onRemove)
                    .frame(width: 24, height: 20)
                    .anchorPreference(key: WorktreeControlAnchors.self, value: .bounds) { [.removeWorktree: $0] }
            } else if showsDivergence {
                divergence
            }
        }
        .font(.system(size: 11))
        .padding(.vertical, 4)
        .padding(.trailing, WorktreeRowGeometry.horizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The divergence summary, for the status line when `showsDivergence` is false.
    var divergence: some View {
        WorktreeRowGutter(stats: entry.state.hasOnDiskWorktree ? stats : nil, baseRef: baseRef, theme: theme).fixedSize()
    }

    /// @spec LAYOUT-2.26
    /// When a worktree name differs from its branch, the sidebar shall retain both in the heading tooltip while displaying only the uppercase worktree name.
    private var branchLabel: some View {
        Text(displayName.uppercased()).accessibilityLabel(displayName)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.3)
            .strikethrough(entry.state == .stale)
            // LAYOUT-2.215: brighter than the status line; full when selected.
            .foregroundColor(entry.state == .stale ? theme.sidebarStaleText : theme.sidebarPrimaryText(isActive: isActive))
            .lineLimit(1).truncationMode(.tail)
            .help(entry.displayBranch == displayName ? displayName : "\(displayName)\n\(entry.displayBranch)")
    }

}

/// A row's identity, beside its name and status line. Clicking it selects the
/// row like the rest of the block; its menu edits the emoji (LAYOUT-2.96).
struct WorktreeRowIdentitySlot: View {
    let entry: WorktreeEntry
    let displayName: String
    let isMainCheckout: Bool
    let theme: GhosttyTheme
    let prBadge: PRBadge?
    let status: SidebarRowStatus
    var project: SidebarProject? = nil
    var projectIconData: Data? = nil
    /// The rendered agent drawing, shown in place of the emoji (LAYOUT-2.202).
    var drawingData: Data? = nil
    var identityMenu: ((NSView) -> NSMenu)? = nil

    private var resolvedProject: SidebarProject {
        project ?? SidebarProject(id: entry.path, repositoryID: entry.path, name: displayName)
    }

    private var drawingIdentity: WorktreeIconIdentity {
        .resolve(isMainCheckout: isMainCheckout, emoji: entry.emoji, drawingRevision: entry.drawing?.revision,
                 emojiChosenByUser: entry.emojiChosenByUser)
    }

    var body: some View {
        switch WorktreeRow.leadingSequence(isMainCheckout: isMainCheckout, hasEmoji: entry.emoji != nil || drawingData != nil,
                                           hasPR: false, isInFlight: entry.state.isInFlight)[0] {
        case .projectIcon:
            SidebarWorktreeRowIdentity(identity: .project, project: resolvedProject, imageData: projectIconData, status: status)
        case .emoji:
            if case .drawing = drawingIdentity, let drawingData {
                menuTarget(SidebarWorktreeRowIdentity(identity: drawingIdentity, project: resolvedProject,
                                                      imageData: drawingData, status: status)
                    .accessibilityHidden(true))
            } else {
                menuTarget(SidebarWorktreeRowIdentity(identity: .emoji(entry.emoji ?? ""), project: resolvedProject, status: status)
                    .accessibilityHidden(true))
            }
        default:
            menuTarget(typeIcon)
        }
    }

    @ViewBuilder
    private func menuTarget<Content: View>(_ content: Content) -> some View {
        if let identityMenu, !entry.state.isInFlight {
            content.rightClickMenu(anchored: identityMenu)
        } else {
            content
        }
    }

    /// Fallback when a linked worktree has no emoji: `arrow.triangle.branch`,
    /// or `arrow.triangle.pull` once a PR/MR is associated. The icon's color encodes the
    /// worktree's running state: dim foreground when closed, green when
    /// running, yellow when stale. In-flight rows (`.creating` /
    /// `.deleting`) get a `ProgressView` in place of the icon so the
    /// user sees that work is in flight rather than a static row that
    /// looks identical to a finished one.
    @ViewBuilder
    private var typeIcon: some View {
        if entry.state.isInFlight {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: WorktreeRowIcon.symbolName(isMainCheckout: isMainCheckout, hasPR: prBadge != nil))
                .font(.system(size: 13))
                .foregroundColor(theme.core.worktreeStateIcon(entry.state.wireState))
        }
    }
}
