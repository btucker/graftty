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
@Suite("""
SidebarWorktreeLabel

@spec GIT-2.10: When the application renders a worktree's branch name in the UI (the breadcrumb bar per `LAYOUT-1.3`, the secondary label in the sidebar row, and the main-checkout label in right-click "Move to <name>" menu entries — both in the sidebar pane row's menu and the terminal surface menu, per `PWD-1.1` / `PWD-1.3` / `TERM-8.10`), it shall read `WorktreeEntry.displayBranch` rather than `WorktreeEntry.branch`. `displayBranch` strips every Unicode bidirectional-override scalar (same ranges as `PR-5.5`) so a collaborator-controlled branch name like `"feat\\u{202E}lanigiro"` — which git accepts and which propagates into `state.json` via `git worktree list --porcelain` — can't render RTL-reversed in the breadcrumb, row, or menu items. `branch` itself is preserved unchanged so downstream `git` subprocess calls, `gh pr list --head <branch>`, and the `PRStatusStore.isFetchableBranch` gate keep operating on the real ref. This is the same strip-not-reject policy `PR-5.5` uses for externally-sourced text. The shared `SidebarWorktreeLabel.text(for:inRepoAtPath:siblingPaths:)` helper is the single call site for sidebar-adjacent labels so menu items and the row can't drift on the main-checkout path.
""")
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

    @Test func repoLabelsMatchPerRowLabels() {
        let main = WorktreeEntry(path: "/repo", branch: "main")
        let nested = WorktreeEntry(path: "/repo/.worktrees/feature-x", branch: "feature/x")
        let sibling = WorktreeEntry(path: "/repo/.other/feature-x", branch: "feature/x-alt")
        let worktrees = [main, nested, sibling]

        let labels = SidebarWorktreeLabel.texts(
            for: worktrees,
            inRepoAtPath: "/repo"
        )
        let siblingPaths = worktrees.map(\.path)

        for worktree in worktrees {
            #expect(labels[worktree.id] == SidebarWorktreeLabel.text(
                for: worktree,
                inRepoAtPath: "/repo",
                siblingPaths: siblingPaths
            ))
        }
    }
}
