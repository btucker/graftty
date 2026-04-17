import SwiftUI
import EspalierKit

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

    var body: some View {
        HStack(spacing: 4) {
            Text("↳")
                .font(.caption)
                .fontWeight(isFocusedPane ? .bold : .regular)
                .foregroundColor(theme.foreground.opacity(arrowOpacity))
            Text(title.isEmpty ? "shell" : title)
                .font(.caption)
                .fontWeight(isFocusedPane ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(theme.foreground.opacity(titleOpacity))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.leading, 28)
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

    var body: some View {
        HStack(spacing: 6) {
            // Stale worktrees get no gutter content per DIVERGE-1.6, but
            // the width stays reserved for vertical alignment.
            WorktreeRowGutter(
                stats: entry.state == .stale ? nil : stats,
                theme: theme
            )
            stateIndicator
            typeIcon
            branchLabel
            Spacer()
            attentionBadge
        }
        .padding(.vertical, 4)
        // Asymmetric: no leading padding so the divergence gutter sits flush
        // against the sidebar's leading edge (DIVERGE-1.1); trailing padding
        // keeps the attention badge and branch text off the scrollbar.
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// `house` for the repo's main checkout, `arrow.triangle.branch` for
    /// linked worktrees. Gives Andy an at-a-glance way to distinguish
    /// "the canonical source" from "an ephemeral branch workspace"
    /// without reading labels.
    @ViewBuilder
    private var typeIcon: some View {
        Image(systemName: isMainCheckout ? "house" : "arrow.triangle.branch")
            .font(.system(size: 10))
            .foregroundColor(theme.foreground.opacity(0.6))
            .frame(width: 12)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch entry.state {
        case .closed:
            Circle()
                .strokeBorder(theme.foreground.opacity(0.5), lineWidth: 1)
                .frame(width: 8, height: 8)
        case .running:
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
        case .stale:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.yellow)
        }
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
            // showing both would be noise).
            if entry.branch != displayName {
                Text(entry.branch)
                    .font(.caption)
                    .foregroundColor(theme.foreground.opacity(0.45))
            }
        }
    }

    @ViewBuilder
    private var attentionBadge: some View {
        if let attention = entry.attention {
            Text(attention.text)
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.red)
                .foregroundColor(.white)
                .clipShape(Capsule())
        }
    }
}
