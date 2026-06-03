import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol

/// Red pill used by both `WorktreeRow` (worktree-scoped CLI notify) and
/// `PaneTitleRow` (pane-scoped shell-integration pings). Centralized so
/// a restyle — font, padding, color — lands in one place and the two
/// scopes can't drift visually.
struct AttentionCapsule: View {
    let style: AttentionCapsuleStyle

    var body: some View {
        capsuleContent
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.red)
            .foregroundColor(.white)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var capsuleContent: some View {
        switch style {
        case let .needsInput(label):
            // Agent "needs input" renders as an icon; keep the human text
            // as the accessibility label + tooltip.
            Image(systemName: AttentionCapsuleStyle.needsInputSymbol)
                .accessibilityLabel(label)
                .help(label)
        case let .text(text):
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// Child row under a running worktree showing a single pane's title
/// (from libghostty's `SET_TITLE` action). Indented to communicate the
/// hierarchy; the `↳` glyph is there for at-a-glance parsing when the
/// worktree has multiple panes. The row has no background — the enclosing
/// worktree block draws one unified highlight across both row types.
/// Focus within that block is indicated by text emphasis instead.
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
    /// True while this pane's claude session is busy (AGENT-2.2). Tints the
    /// title green — but only when no attention capsule is present, since a
    /// needs-input ping (claude waiting) supersedes "working".
    let isBusy: Bool
    let theme: GhosttyTheme
    /// When non-nil, an attention capsule renders to the *right* of the
    /// pane title (LAYOUT-2.30); the title truncates to make room rather
    /// than being replaced. Agent "needs input" (`.needsInput`) shows an
    /// icon; `graftty notify` / ✓! (`.text`) show their text. Cleared when
    /// the user clicks the worktree (STATE-2.4). Worktree-scoped pings
    /// render on the worktree row instead (STATE-2.3).
    let attentionStyle: AttentionCapsuleStyle?
    /// Port bindings detected for this pane's process subtree (PORTS-3.1).
    /// Hidden while an attention capsule is shown (PORTS-3.4) so an active
    /// attention ping owns the row's secondary surface unambiguously.
    let portBindings: [PortBinding]

    var shouldRenderPortChips: Bool {
        attentionStyle == nil && !portBindings.isEmpty
    }

    /// Busy style applies only when no capsule is shown (ping supersedes).
    /// Shared with the iPad row via `PaneTitleBusyStyle` so the rule can't
    /// drift.
    private var titleIsBusy: Bool {
        PaneTitleBusyStyle.applies(isBusy: isBusy, hasAttentionCapsule: attentionStyle != nil)
    }

    @ViewBuilder
    private var titleText: some View {
        // AGENT-2.2: a busy pane renders its (already-animating) title in
        // italic — a quiet "working" cue rather than a color shift. Apply
        // italic at the *Text* level (Text.italic(), not the View
        // `.italic(_:)` modifier): when a Text-level `.fontWeight` is set,
        // the focused pane's `.semibold` wins over the View-level italic and
        // drops it, so the slant only showed on non-focused (regular) rows.
        let base = Text(title.isEmpty ? "shell" : title)
            .font(.caption)
            .fontWeight(isFocusedPane ? .semibold : .regular)
        (titleIsBusy ? base.italic() : base)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundColor(theme.paneTitle(
                isFocusedPane: isFocusedPane,
                isActiveWorktree: isActiveWorktree,
                hasTitle: !title.isEmpty
            ))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("↳")
                .font(.caption)
                .fontWeight(isFocusedPane ? .bold : .regular)
                .foregroundColor(theme.paneArrow(
                    isFocusedPane: isFocusedPane,
                    isActiveWorktree: isActiveWorktree
                ))
            if let attentionStyle {
                // LAYOUT-2.30: title (yields/truncates) + pill (keeps
                // intrinsic width) on one line. A plain HStack — NOT
                // FlowLayout — so the title truncates instead of the pill
                // wrapping below it.
                titleText
                    .layoutPriority(0)
                AttentionCapsule(style: attentionStyle)
                    .layoutPriority(1)
            } else {
                // Title + port chips share a FlowLayout so wrapped chips
                // hang under the title text (PORTS-3.3).
                FlowLayout(spacing: 4, rowSpacing: 3) {
                    titleText
                    if shouldRenderPortChips {
                        ForEach(portBindings, id: \.self) { binding in
                            PortChip(binding: binding, theme: theme)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        // Place the `↳` glyph's vertical stroke directly under the center
        // of the worktree row's house/branch icon above. The worktree
        // row's leading padding is 8pt + 12pt icon = icon center at 14pt.
        // The `↳` character's vertical stroke sits at its own left edge,
        // so a 14pt leading padding drops that stroke onto the icon's
        // vertical centerline.
        .padding(.leading, 14)
        .padding(.trailing, 8)
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
    /// associated. Drives (a) the leading-icon swap to the pull-request
    /// glyph (PR-3.1) and (b) the colored `#<number>` badge rendered
    /// between icon and branch label (PR-3.2, PR-3.3). `PRBadge` is
    /// deliberately narrower than `PRInfo` so unrelated changes (CI
    /// checks, title, fetchedAt) don't invalidate the row on each poll.
    let prBadge: PRBadge?
    /// Worktree-scoped attention (STATE-2.3). Driven by the CLI's
    /// `graftty notify` path (or a worktree-scoped agent stop). Rendered as
    /// a red capsule next to the branch label, visible regardless of the
    /// worktree's running state so a ping set on a closed worktree stays
    /// reachable.
    let attentionStyle: AttentionCapsuleStyle?

    var body: some View {
        HStack(spacing: 6) {
            typeIcon
            if let prBadge {
                prBadgeLabel(prBadge)
            }
            branchLabel
            if let attentionStyle {
                AttentionCapsule(style: attentionStyle)
            }
            Spacer()
            WorktreeRowGutter(
                stats: entry.state.hasOnDiskWorktree ? stats : nil,
                baseRef: baseRef,
                theme: theme
            )
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// `house` for the repo's main checkout, `arrow.triangle.branch` for
    /// linked worktrees, and `arrow.triangle.pull` once a PR/MR is
    /// associated with the worktree. The icon's color encodes the
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
                .frame(width: 12)
        } else {
            Image(systemName: WorktreeRowIcon.symbolName(
                isMainCheckout: isMainCheckout,
                hasPR: prBadge != nil
            ))
                .font(.system(size: 10))
                .foregroundColor(typeIconColor)
                .frame(width: 12)
        }
    }

    private var typeIconColor: Color {
        theme.core.worktreeStateIcon(entry.state.wireState)
    }

    @ViewBuilder
    private func prBadgeLabel(_ badge: PRBadge) -> some View {
        let tone = PRBadgeStyle.tone(
            state: badge.state,
            checks: badge.checks,
            mergeable: badge.mergeable
        )
        Button {
            NSWorkspace.shared.open(badge.url)
        } label: {
            Text("#\(badge.number)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(color(for: tone))
                .padding(.horizontal, 3)
                .overlay {
                    if tone == .conflicting {
                        // Outline ring on conflict — pairs with the
                        // breadcrumb's "merge conflict" pill so both
                        // surfaces share the same visual language.
                        // PR-8.20.
                        Capsule()
                            .strokeBorder(color(for: tone), lineWidth: 1)
                    }
                }
                .modifier(PulseIfPending(isPending: tone.pulses))
        }
        .buttonStyle(.plain)
        .help("Open #\(badge.number) on \(badge.url.host ?? "")")
        .accessibilityLabel(badgeAccessibilityLabel(badge, tone: tone))
    }

    private func color(for tone: PRBadgeStyle.Tone) -> Color {
        switch tone {
        case .open:        return PRInfo.State.open.statusColor
        case .merged:      return PRInfo.State.merged.statusColor
        case .closed:      return PRInfo.State.closed.statusColor
        case .ciFailure:   return PRInfo.Checks.failure.statusColor
        case .ciPending:   return PRInfo.Checks.pending.statusColor
        case .conflicting: return PRInfo.Mergeable.conflicting.statusColor
        }
    }

    private func badgeAccessibilityLabel(_ badge: PRBadge, tone: PRBadgeStyle.Tone) -> String {
        let stateWord: String
        switch badge.state {
        case .open:   stateWord = "open"
        case .merged: stateWord = "merged"
        case .closed: stateWord = "closed"
        }
        let suffix: String
        switch tone {
        case .ciFailure:   suffix = ", CI failing"
        case .ciPending:   suffix = ", CI running"
        case .conflicting: suffix = ", merge conflict"
        case .open, .merged, .closed: suffix = ""
        }
        return "Pull request \(badge.number), \(stateWord)\(suffix). Click to open in browser."
    }

    /// @spec LAYOUT-2.26
    /// When the main-checkout worktree's current branch differs from
    /// the repository's resolved default branch, the sidebar row shall
    /// render the current branch as a dimmed secondary caption beneath
    /// the primary label.
    @ViewBuilder
    private var branchLabel: some View {
        HStack(spacing: 6) {
            // Primary label: directory name (possibly disambiguated with
            // parent) — the identity of the worktree as the user set it up.
            if entry.state == .stale {
                Text(displayName)
                    .strikethrough()
                    .foregroundColor(theme.sidebarStaleText)
            } else if isMainCheckout {
                // Italic distinguishes the main checkout from feature
                // worktrees; the label itself is the worktree's display
                // name (e.g. "main") so the user sees the actual branch
                // identity rather than a generic placeholder.
                Text(displayName)
                    .italic()
                    .foregroundColor(theme.sidebarPrimaryText(isActive: isActive))
            } else {
                Text(displayName)
                    .foregroundColor(theme.sidebarPrimaryText(isActive: isActive))
            }

            // Secondary label: git branch, dimmed. Skip when it duplicates
            // the displayName (when the directory name matches the branch,
            // showing both would be noise). Render the sanitized
            // `displayBranch` so a BIDI-override in the ref name can't
            // visually deceive via RTL-reversal; the raw `branch` stays
            // available for the dedup comparison and git operations.
            if entry.displayBranch != displayName {
                Text(entry.displayBranch)
                    .font(.caption)
                    .foregroundColor(theme.sidebarSecondaryText)
            }
        }
    }

}
