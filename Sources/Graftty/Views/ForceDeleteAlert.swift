import AppKit

/// Builds `SheetAlert.Configuration`s for the GIT-4.4 (recoverable —
/// "Force Delete" button) and GIT-4.11 (final — single-button)
/// failure dialogs presented when `git worktree remove` exits
/// non-zero. The informative-text formatter is shared between them
/// since GIT-4.11 messages are already pre-formatted by
/// `DeleteWorktreeFlow.delete`. Pure value factories so the dialogs'
/// text and button labels stay regression-proof without booting
/// NSAlert.
enum ForceDeleteAlert {

    /// Above this many `git status --short` lines we truncate and
    /// append an ellipsis line. Hundreds of untracked paths would
    /// otherwise stretch the alert past the screen edge.
    static let maxStatusLines = 30

    /// Two-button "Could not delete worktree / Force Delete" dialog
    /// for GIT-4.4. Cancel is the primary (safe) button; Force Delete
    /// is the secondary so the destructive action requires a
    /// deliberate second-button click.
    static func gitFailedForceableConfiguration(stderr: String, status: String) -> SheetAlert.Configuration {
        SheetAlert.Configuration(
            messageText: "Could not delete worktree",
            informativeText: informativeText(stderr: stderr, status: status),
            style: .warning,
            primaryButton: "Cancel",
            secondaryButton: "Force Delete"
        )
    }

    /// Single-button "Could not delete worktree" dialog for GIT-4.11
    /// (non-`gitFailed` errors: missing git binary, subprocess launch
    /// failure, timeout). `message` is `DeleteWorktreeFlow.delete`'s
    /// pre-formatted error string.
    static func gitFailedFinalConfiguration(message: String) -> SheetAlert.Configuration {
        SheetAlert.Configuration(
            messageText: "Could not delete worktree",
            informativeText: message,
            style: .warning,
            primaryButton: "OK",
            secondaryButton: nil
        )
    }

    /// Builds the recoverable dialog's body: git's stderr (or a
    /// fallback) followed by the `git status --short` block below a
    /// blank-line separator.
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
