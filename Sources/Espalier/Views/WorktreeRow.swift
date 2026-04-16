import SwiftUI
import EspalierKit

struct WorktreeRow: View {
    let entry: WorktreeEntry
    let isSelected: Bool
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

    var body: some View {
        HStack(spacing: 6) {
            stateIndicator
            typeIcon
            branchLabel
            Spacer()
            attentionBadge
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Subtle theme-aware highlight for the active worktree.
            // Foreground at low opacity reads well on both dark and
            // light themes; the 16% value gives enough contrast to be
            // clearly "selected" without shouting.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? theme.foreground.opacity(0.16) : .clear)
        )
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
                        isSelected
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
