import Testing
@testable import Graftty

/// Pins the formatting logic for the GIT-4.4 failure alert's informative
/// text block. Tests the pure formatter — the NSAlert dialog itself
/// (modal AppKit) is exercised manually.
@Suite("ForceDeleteAlert")
struct ForceDeleteAlertTests {

    @Test("""
@spec GIT-4.4: If `git worktree remove` fails (e.g., the worktree contains uncommitted changes), then the application shall present an error alert whose informative text leads with git's stderr and, when non-empty, appends the `git status --short` output below a blank-line separator, and whose buttons are "Cancel" (default) and "Force Delete"; the worktree entry and any running terminal surfaces shall remain intact unless the user confirms Force Delete (GIT-4.12).
""")
    func combinesStderrAndStatusWithBlankLineSeparator() {
        let body = ForceDeleteAlert.informativeText(
            stderr: "fatal: 'wt' contains modified or untracked files, use --force to delete it",
            status: " M tracked.txt\n?? untracked.txt"
        )
        #expect(body.contains("fatal: 'wt' contains modified or untracked files"))
        #expect(body.contains(" M tracked.txt"))
        #expect(body.contains("?? untracked.txt"))
        // Blank line between stderr and status.
        #expect(body.contains("--force to delete it\n\n M tracked.txt"))
    }

    @Test func emptyStderrUsesFallbackString() {
        let body = ForceDeleteAlert.informativeText(stderr: "", status: " M file.swift")
        #expect(body.hasPrefix("git worktree remove failed"))
        #expect(body.contains(" M file.swift"))
    }

    @Test func emptyStatusOmitsTrailingSeparator() {
        let body = ForceDeleteAlert.informativeText(
            stderr: "fatal: something else",
            status: ""
        )
        #expect(body == "fatal: something else")
    }

    /// A worktree with hundreds of untracked paths must not blow the
    /// alert past the screen. Truncate above a generous cap and append
    /// an ellipsis line so the user knows there's more.
    @Test func longStatusIsTruncated() {
        let manyLines = (1...200).map { "?? f\($0).txt" }.joined(separator: "\n")
        let body = ForceDeleteAlert.informativeText(stderr: "fatal: dirty", status: manyLines)
        let lineCount = body.components(separatedBy: "\n").count
        #expect(lineCount <= ForceDeleteAlert.maxStatusLines + 4)  // stderr + blank + cap + ellipsis
        #expect(body.contains("…"))
        #expect(body.contains("?? f1.txt"))
        #expect(!body.contains("?? f200.txt"))
    }

    /// Pins the GIT-4.4 factory's shape: warning style, message text,
    /// Cancel as the primary (safe-default) button, Force Delete as
    /// the secondary, and informative text built by the existing
    /// formatter. The dialog's behavioural contract lives in the
    /// GIT-4.4 spec test above.
    @Test func recoverableConfiguration() {
        let config = ForceDeleteAlert.recoverableConfiguration(
            stderr: "fatal: dirty",
            status: " M file.swift"
        )
        #expect(config.messageText == "Could not delete worktree")
        #expect(config.informativeText.contains("fatal: dirty"))
        #expect(config.informativeText.contains(" M file.swift"))
        #expect(config.style == .warning)
        #expect(config.primaryButton == "Cancel")
        #expect(config.secondaryButton == "Force Delete")
    }

    /// Pins the GIT-4.11 factory's shape: warning style, single OK
    /// button (no secondary), and the supplied error message as
    /// informative text. The dialog's behavioural contract lives in
    /// the GIT-4.11 inventory entry until Task 4 wires it up.
    @Test func finalFailureConfiguration() {
        let config = ForceDeleteAlert.finalFailureConfiguration(
            message: "git binary not found"
        )
        #expect(config.messageText == "Could not delete worktree")
        #expect(config.informativeText == "git binary not found")
        #expect(config.style == .warning)
        #expect(config.primaryButton == "OK")
        #expect(config.secondaryButton == nil)
    }
}
