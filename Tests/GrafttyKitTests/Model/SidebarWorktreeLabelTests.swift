import Testing
import Foundation
@testable import GrafttyKit

/// GIT-2.6 originally named the breadcrumb + secondary-row renderers
/// as the two UI surfaces that read `branch`; it missed the right-
/// click "Move to <name>" menu items, which also render the main
/// checkout's branch. Those items passed the raw `branch` through,
/// so a collaborator-controlled branch with a BIDI-override scalar
/// rendered RTL-reversed in the menu. The shared helper now routes
/// through `displayBranch`.
@Suite("SidebarWorktreeLabel")
struct SidebarWorktreeLabelTests {

    @Test func mainCheckoutUsesSanitizedDisplayBranch() {
        let entry = WorktreeEntry(path: "/repo", branch: "feat\u{202E}lanigiro")
        let label = SidebarWorktreeLabel.text(
            for: entry,
            inRepoAtPath: "/repo",
            siblingPaths: ["/repo"]
        )
        // displayBranch strips U+202E → "featlanigiro" (the scalar
        // removed, leaving the visible characters only).
        #expect(label == "featlanigiro")
        // Raw `branch` is preserved for git operations; only the
        // rendered label is sanitized.
        #expect(entry.branch == "feat\u{202E}lanigiro")
    }

    @Test func mainCheckoutWithCleanBranchReturnsBranch() {
        let entry = WorktreeEntry(path: "/repo", branch: "main")
        let label = SidebarWorktreeLabel.text(
            for: entry,
            inRepoAtPath: "/repo",
            siblingPaths: ["/repo"]
        )
        #expect(label == "main")
    }

    @Test func linkedWorktreeUsesDisplayName() {
        let entry = WorktreeEntry(path: "/repo/.worktrees/feature-x", branch: "feature/x")
        let label = SidebarWorktreeLabel.text(
            for: entry,
            inRepoAtPath: "/repo",
            siblingPaths: ["/repo", "/repo/.worktrees/feature-x"]
        )
        #expect(label == "feature-x")
    }
}
