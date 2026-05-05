import SwiftUI
import AppKit
import GrafttyKit

/// Red pill used by both `WorktreeRow` (worktree-scoped CLI notify) and
/// `PaneTitleRow` (pane-scoped shell-integration pings). Centralized so
/// a restyle — font, padding, color — lands in one place and the two
/// scopes can't drift visually.
struct AttentionCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.red)
            .foregroundColor(.white)
            .clipShape(Capsule())
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
    let theme: GhosttyTheme
    /// When non-nil, the pane title text is replaced by this string
    /// rendered inside a red capsule — a pane-scoped attention ping
    /// driven by shell-integration events (`NOTIF-2.x`). Cleared when
    /// the user clicks the worktree (STATE-2.4). Worktree-scoped
    /// `graftty notify` text renders on the enclosing worktree row
    /// instead; see STATE-2.3.
    let attentionText: String?

    var body: some View {
        HStack(spacing: 4) {
            Text("↳")
                .font(.caption)
                .fontWeight(isFocusedPane ? .bold : .regular)
                .foregroundColor(theme.foreground.opacity(arrowOpacity))
            if let attentionText {
                AttentionCapsule(text: attentionText)
            } else {
                Text(title.isEmpty ? "shell" : title)
                    .font(.caption)
                    .fontWeight(isFocusedPane ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(theme.foreground.opacity(titleOpacity))
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

    /// Four-way brightness ladder so the eye can parse the hierarchy at a
    /// glance: focused-in-active > other-pane-in-active > empty-title-in-active
    /// > inactive-worktree. The numbers are tuned to the 0.16 alpha block
    /// highlight so contrast stays clean on both light and dark themes.
    private var titleOpacity: Double {
        if isFocusedPane { return 1.0 }
        if isActiveWorktree { return title.isEmpty ? 0.55 : 0.75 }
        return title.isEmpty ? 0.35 : 0.55
    }

    private var arrowOpacity: Double {
        if isFocusedPane { return 0.75 }
        return isActiveWorktree ? 0.5 : 0.35
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
    /// Worktree-scoped attention text (STATE-2.3). Driven by the CLI's
    /// `graftty notify` path. Rendered as a red capsule next to the
    /// branch label, visible regardless of the worktree's running state
    /// so a ping set on a closed worktree stays reachable.
    let attentionText: String?

    var body: some View {
        HStack(spacing: 6) {
            typeIcon
            if let prBadge {
                prBadgeLabel(prBadge)
            }
            branchLabel
            if let attentionText {
                AttentionCapsule(text: attentionText)
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
    /// running, yellow when stale. While the entry is in `.creating` —
    /// the optimistic placeholder shown between the user's submit and
    /// `git worktree add` returning — a small `ProgressView` replaces the
    /// icon so the user sees that work is in flight rather than a static
    /// row that looks identical to a finished one.
    @ViewBuilder
    private var typeIcon: some View {
        if entry.state == .creating {
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
        switch entry.state {
        case .closed, .creating: return theme.foreground.opacity(0.6)
        case .running: return .green
        case .stale: return .yellow
        }
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
        }
        let suffix: String
        switch tone {
        case .ciFailure:   suffix = ", CI failing"
        case .ciPending:   suffix = ", CI running"
        case .conflicting: suffix = ", merge conflict"
        case .open, .merged: suffix = ""
        }
        return "Pull request \(badge.number), \(stateWord)\(suffix). Click to open in browser."
    }

    @ViewBuilder
    private var branchLabel: some View {
        HStack(spacing: 6) {
            // Primary label: directory name (possibly disambiguated with
            // parent) — the identity of the worktree as the user set it up.
            if entry.state == .stale {
                Text(displayName)
                    .strikethrough()
                    .foregroundColor(theme.foreground.opacity(0.5))
            } else if isMainCheckout {
                Text("root")
                    .italic()
                    .foregroundColor(
                        isActive
                            ? theme.foreground
                            : theme.foreground.opacity(0.8)
                    )
            } else {
                Text(displayName)
                    .foregroundColor(
                        isActive
                            ? theme.foreground
                            : theme.foreground.opacity(0.8)
                    )
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
                    .foregroundColor(theme.foreground.opacity(0.45))
            }
        }
    }

}
