import SwiftUI
import GrafttyKit
import GrafttyCommandUI

/// Trailing divergence indicator on each sidebar worktree row showing
/// ahead/behind commits vs. the origin default branch, with a `+` suffix
/// on the ahead count when the worktree has uncommitted changes. The
/// `+I -D` insertion/deletion detail is surfaced on hover via `.help()`
/// rather than rendered inline, keeping the sidebar uncluttered.
///
/// Renders nothing when the worktree is at parity / has no resolvable
/// origin default / is stale.
struct WorktreeRowGutter: View {
    let stats: WorktreeStats?
    let baseRef: String?
    let theme: GhosttyTheme

    var body: some View {
        if let stats, !stats.isEmpty {
            // `↑X[+] ↓Y`, shared with the mobile worktree row.
            SidebarDivergenceGutter(
                ahead: stats.ahead,
                behind: stats.behind,
                hasUncommittedChanges: stats.hasUncommittedChanges,
                aheadColor: Self.aheadColor(theme)
            )
            .help(tooltip(stats))
        }
    }

    /// The Mac dims the ahead count to 55% of the foreground; mobile uses
    /// the sidebar's 45% secondary text.
    static func aheadColor(_ theme: GhosttyTheme) -> Color {
        theme.foreground.opacity(0.55)
    }

    /// Hover tooltip detail: the committed-diff line counts, optionally
    /// followed by a note about uncommitted work and the base ref the
    /// diff was computed against. Shape is consistent across variants so
    /// the user knows where to look.
    private func tooltip(_ s: WorktreeStats) -> String {
        var parts: [String] = []
        if s.insertions > 0 || s.deletions > 0 {
            var linesParts: [String] = []
            if s.insertions > 0 { linesParts.append("+\(s.insertions)") }
            if s.deletions > 0 { linesParts.append("-\(s.deletions)") }
            parts.append("\(linesParts.joined(separator: " ")) lines")
        }
        if s.hasUncommittedChanges {
            parts.append("uncommitted changes")
        }
        let body = parts.joined(separator: ", ")
        if let baseRef, !baseRef.isEmpty, !body.isEmpty {
            return "\(body) vs. \(baseRef)"
        }
        return body
    }
}
