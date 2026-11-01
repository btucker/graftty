import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

private enum WorktreeRowGeometry {
    static let identityWidth: CGFloat = 18
    static let spacing: CGFloat = 6
    static let horizontalInset: CGFloat = 8
    static let paneIndent: CGFloat = 18
}

/// Child row under a running worktree showing a single pane's title
/// (from libghostty's `SET_TITLE` action). Indented to communicate the
/// hierarchy; the `↳` glyph is there for at-a-glance parsing when the
/// worktree has multiple panes. The row has no background — the enclosing
/// worktree block draws one unified highlight across both row types.
/// Focus within that block is indicated by text emphasis instead.
/// @spec LAYOUT-2.63: While a worktree displays pane rows, the application shall place orange attention counts before the corresponding pane titles, assigning worktree-wide attention to the first pane and keeping the counts separate from Git indicators.
struct PaneTitleRow: View {
    let title: String
    /// True when this row's worktree is the currently-selected one. Drives
    /// the baseline brightness of text so non-focused panes in the active
    /// worktree still look "lit up" vs panes in inactive worktrees.
    let isActiveWorktree: Bool
    /// True only for the single pane that currently has keyboard focus
    /// within the active worktree. Gets the brightest text treatment and a
    /// bolder `↳` glyph so the user can see "typing goes here".
    let isFocusedPane: Bool
    /// True while this pane's claude session is busy (AGENT-2.2). Italicizes
    /// the title — but only when no attention capsule is present, since a
    /// needs-input ping (claude waiting) supersedes "working".
    let isBusy: Bool
    let theme: GhosttyTheme
    /// When non-nil, an attention capsule renders to the *right* of the
    /// pane title (LAYOUT-2.30); the title truncates to make room rather
    /// than being replaced. Agent "needs input" (`.needsInput`) shows an
    /// icon; `graftty notify` / ✓! (`.text`) show their text. Cleared when
    /// the agent resumes or the request is dismissed; notifications clear
    /// when the user clicks the worktree (STATE-2.4). Worktree-scoped pings
    /// render on the worktree row instead (STATE-2.3).
    let attentionStyle: AttentionCapsuleStyle?
    /// Port bindings detected for this pane's process subtree (PORTS-3.1).
    /// Hidden while an attention capsule is shown (PORTS-3.4) so an active
    /// attention ping owns the row's secondary surface unambiguously.
    let portBindings: [PortBinding]
    var needsInput: Bool = false
    var agent: AgentSessionInfo? = nil
    var attentionCount: Int = 0
    var onOpenPort: ((PortBinding) -> Void)? = nil
    var shouldRenderPortChips: Bool {
        attentionStyle == nil && !portBindings.isEmpty
    }
    /// The Mac aligns the marker, title and port chips on the first text
    /// baseline; mobile keeps the shared row's `.center` default.
    static let titleAlignment: VerticalAlignment = .firstTextBaseline

    var body: some View {
        // Title, marker and attention capsule are shared with mobile
        // (`SidebarPaneTitleRow`); the Mac adds port chips, which share a
        // FlowLayout with the title so wrapped chips hang under it (PORTS-3.3).
        SidebarPaneTitleRow(
            title: title,
            isFocusedPane: isFocusedPane,
            isActiveWorktree: isActiveWorktree,
            isBusy: isBusy,
            attentionStyle: attentionStyle,
            attentionCount: attentionCount,
            theme: theme.core,
            needsInput: needsInput,
            agent: agent,
            alignment: Self.titleAlignment
        ) { titleText in
            FlowLayout(spacing: 4, rowSpacing: 3) {
                titleText
                if shouldRenderPortChips {
                    ForEach(portBindings, id: \.self) { binding in
                        PortChip(binding: binding, theme: theme, onOpen: onOpenPort.map { action in { action(binding) } })
                    }
                }
            }
        }
        .padding(.vertical, 2)
        // Keep attention in the arrow slot so a count sits beside its pane
        // without pushing the title past the worktree name.
        .padding(.horizontal, WorktreeRowGeometry.horizontalInset)
        .padding(.leading, WorktreeRowGeometry.paneIndent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Minimal flow layout: wraps subviews to next line at container width
/// while preserving inline layout on each row. Used by `PaneTitleRow` so
/// wrapped port chips align under the title text rather than flush to
/// the row's leading edge (PORTS-3.3). Subviews are queried with the
/// row's available width (not `.unspecified`) so a `Text` with
/// `.lineLimit(1)` truncates instead of reporting its unwrapped natural
/// width — that overflow is what would otherwise clip the enclosing
/// worktree block's `.listRowInsets` outdent (LAYOUT-2.22).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var rowSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let childProposal = ProposedViewSize(width: maxWidth, height: nil)
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(childProposal)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + rowSpacing
                maxRowWidth = max(maxRowWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, rowWidth - spacing)
        return CGSize(width: maxRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let childProposal = ProposedViewSize(width: bounds.width, height: nil)
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(childProposal)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct WorktreeRow: View {
    let entry: WorktreeEntry
    /// True when this is the currently-selected worktree. Used only for
    /// *text* emphasis; the row's highlight background is drawn by the
    /// enclosing worktree block in SidebarView, which spans both this row
    /// and any pane rows beneath it.
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
    /// Worktree-scoped attention (STATE-2.3). Driven by the CLI's
    /// `graftty notify` path (or a worktree-scoped agent stop). Rendered as
    /// a red capsule next to the branch label, visible regardless of the
    /// worktree's running state so a ping set on a closed worktree stays
    /// reachable.
    let attentionStyle: AttentionCapsuleStyle?
    var attentionCount: Int = 0
    var project: SidebarProject? = nil
    var projectIconData: Data? = nil
    /// Right-click menu for the identity slot (LAYOUT-2.96); nil for rows
    /// whose identity is not editable.
    var identityMenu: ((NSView) -> NSMenu)? = nil
    var brief: WorktreeBrief? = nil
    var onRemove: ((NSWindow) -> Void)? = nil

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

    var body: some View {
        HStack(spacing: WorktreeRowGeometry.spacing) {
            if attentionCount > 0 { SidebarActivityBadge(attentionCount) }
            ForEach(Self.leadingSequence(isMainCheckout: isMainCheckout, hasEmoji: entry.emoji != nil, hasPR: prBadge != nil,
                                         isInFlight: entry.state.isInFlight), id: \.self) { item in
                switch item {
                case .projectIcon:
                    ProjectIdentityView(project: project ?? SidebarProject(id: entry.path, repositoryID: entry.path, name: displayName),
                                        imageData: projectIconData, size: WorktreeRowGeometry.identityWidth)
                case .emoji:
                    if let emoji = entry.emoji {
                        identityMenuTarget(Text(emoji).font(.system(size: 15))
                            .frame(width: WorktreeRowGeometry.identityWidth).accessibilityHidden(true))
                    }
                case .typeIcon:
                    identityMenuTarget(typeIcon)
                case .prBadge:
                    if let prBadge {
                        SidebarPRBadge(badge: prBadge)
                            .fixedSize(horizontal: true, vertical: false)
                            .anchorPreference(key: WorktreeControlAnchors.self, value: .bounds) { [.prBadge: $0] }
                    }
                case .label:
                    VStack(alignment: .leading, spacing: 2) {
                        branchLabel
                        if let progress = entry.creationProgress {
                            WorktreeCreationProgressView(progress: progress)
                                .foregroundStyle(theme.sidebarSecondaryText)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)

                }
            }
            if let attentionStyle {
                AttentionCapsule(style: attentionStyle)
            }
            if let onRemove, SidebarMergedWorktreeRemoval.isAvailable(
                prState: prBadge?.state, isMainCheckout: isMainCheckout, state: entry.state.wireState) {
                SidebarRemoveWorktreeButton(name: displayName, color: theme.sidebarSecondaryText, onRemove: onRemove)
                    .frame(width: 24, height: 20)
                    .anchorPreference(key: WorktreeControlAnchors.self, value: .bounds) { [.removeWorktree: $0] }
            } else {
                WorktreeRowGutter(
                    stats: entry.state.hasOnDiskWorktree ? stats : nil,
                    baseRef: baseRef,
                    theme: theme
                ).fixedSize()
            }
        }
        .font(.system(size: 11))
        .padding(.vertical, 4)
        .padding(.horizontal, WorktreeRowGeometry.horizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func identityMenuTarget<Content: View>(_ content: Content) -> some View {
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
            ProgressView()
                .controlSize(.mini)
                .frame(width: WorktreeRowGeometry.identityWidth)
        } else {
            Image(systemName: WorktreeRowIcon.symbolName(
                isMainCheckout: isMainCheckout,
                hasPR: prBadge != nil
            ))
                .font(.system(size: 10))
                .foregroundColor(typeIconColor)
                .frame(width: WorktreeRowGeometry.identityWidth)
        }
    }

    private var typeIconColor: Color {
        theme.core.worktreeStateIcon(entry.state.wireState)
    }

    /// @spec LAYOUT-2.26
    /// When a worktree name differs from its branch, the sidebar shall retain both in the heading tooltip while displaying only the uppercase worktree name.
    private var branchLabel: some View {
        Text(displayName.uppercased()).accessibilityLabel(displayName)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.3)
            .strikethrough(entry.state == .stale)
            .foregroundColor(theme.sidebarSecondaryText)
            .lineLimit(1).truncationMode(.tail)
            .help(entry.displayBranch == displayName ? displayName : "\(displayName)\n\(entry.displayBranch)")
    }

}
