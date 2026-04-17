import SwiftUI
import EspalierKit

/// Fixed-width leading block on each sidebar worktree row showing divergence
/// vs. the origin default branch. Reserves its width even when empty so
/// sibling row contents stay vertically aligned (DIVERGE-1.1, DIVERGE-1.4).
struct WorktreeRowGutter: View {
    let stats: WorktreeStats?
    let theme: GhosttyTheme

    /// Width reserved for the gutter. Sized to fit ~`↑99 ↓99` in caption2
    /// monospaced — larger numbers will still render, just tighter.
    static let width: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let stats, !stats.isEmpty {
                Text(commitsLine(stats))
                Text(linesLine(stats))
            } else {
                // Preserve two-line height when empty so rows with and
                // without stats line up vertically (DIVERGE-1.1). The
                // space characters render invisibly but still contribute
                // baseline height.
                Text(" ")
                Text(" ")
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(theme.foreground.opacity(0.55))
        .frame(width: Self.width, alignment: .leading)
    }

    /// `↑X ↓Y` with zero sides omitted (DIVERGE-1.2). Returns empty string
    /// when both are zero — caller decides whether to render.
    private func commitsLine(_ s: WorktreeStats) -> String {
        var parts: [String] = []
        if s.ahead > 0 { parts.append("↑\(s.ahead)") }
        if s.behind > 0 { parts.append("↓\(s.behind)") }
        return parts.joined(separator: " ")
    }

    /// `+I -D` with zero sides omitted (DIVERGE-1.3).
    private func linesLine(_ s: WorktreeStats) -> String {
        var parts: [String] = []
        if s.insertions > 0 { parts.append("+\(s.insertions)") }
        if s.deletions > 0 { parts.append("-\(s.deletions)") }
        return parts.joined(separator: " ")
    }
}
