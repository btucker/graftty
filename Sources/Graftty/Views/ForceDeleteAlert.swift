import Foundation

/// Pure formatter for the GIT-4.4 "Could not delete worktree" alert's
/// informative text. Lives in its own type so the formatting logic stays
/// testable without booting NSAlert (modal AppKit).
enum ForceDeleteAlert {

    /// Above this many `git status --short` lines we truncate and append
    /// an ellipsis line. Hundreds of untracked paths would otherwise
    /// stretch the alert past the screen edge.
    static let maxStatusLines = 30

    /// Builds the body string: git's stderr (or a fallback) followed by
    /// the `git status --short` block below a blank-line separator.
    static func informativeText(stderr: String, status: String) -> String {
        let head = stderr.isEmpty ? "git worktree remove failed" : stderr
        guard !status.isEmpty else { return head }
        return "\(head)\n\n\(truncate(status))"
    }

    private static func truncate(_ status: String) -> String {
        let lines = status.components(separatedBy: "\n")
        guard lines.count > maxStatusLines else { return status }
        let kept = lines.prefix(maxStatusLines).joined(separator: "\n")
        return "\(kept)\n… (\(lines.count - maxStatusLines) more)"
    }
}
