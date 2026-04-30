import Foundation

/// Snapshot helper used by the GIT-4.4 failure dialog to show the user
/// exactly which paths blocked `git worktree remove` (the typical cause is
/// modified or untracked files). Always returns successfully — if git
/// fails to run for any reason (path missing, not a repo, binary launch
/// failure), an empty string is returned so the dialog can still render
/// the stderr without an exception bubble.
public enum GitStatusCapture {

    /// Runs `git status --short` at `path` and returns the trimmed output.
    /// `--short` is intentionally chosen over the full porcelain output —
    /// it's the format users grep for ("M file.swift", "?? new.txt") and
    /// stays compact in the alert's `informativeText`.
    public static func shortStatus(at path: String) async -> String {
        do {
            let result = try await GitRunner.captureAll(
                args: ["status", "--short"],
                at: path
            )
            guard result.exitCode == 0 else { return "" }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }
}
