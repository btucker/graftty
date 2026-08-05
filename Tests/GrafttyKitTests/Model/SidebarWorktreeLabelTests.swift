import Testing
import Foundation
@testable import GrafttyKit

@Suite("""
SidebarWorktreeLabel

The shared label helper for sidebar-adjacent worktree surfaces (row
label + right-click "Move to <name>" menu items). For managed linked
worktrees, the label is the full path relative to `<repo>/.worktrees`;
external linked worktrees retain basename disambiguation. For the main
checkout, the label is the resolved default branch name —
application-controlled, never user-controlled — so BIDI-override
sanitization (GIT-2.10) is unnecessary on this surface for the
main-checkout path. The secondary caption rendered by `WorktreeRow`
still routes user-controlled `entry.branch` through `displayBranch`,
preserving GIT-2.10 for the row's dimmed current-HEAD line.
""")
struct SidebarWorktreeLabelTests {

    @Test("@spec LAYOUT-2.25: The application shall display the repository's resolved default branch name as the main-checkout sidebar row's primary label, regardless of the worktree's current HEAD.")
    func mainCheckoutLabelUsesResolvedDefaultBranch() {
        let entry = WorktreeEntry(path: "/repo", branch: "feature-x")
        let label = SidebarWorktreeLabel.text(
            for: entry,
            inRepoAtPath: "/repo",
            siblingPaths: ["/repo"],
            defaultBranch: "trunk"
        )
        #expect(label == "trunk")
    }

    @Test("@spec LAYOUT-2.28: The application shall fall back to `main` for the main-checkout row label when no default branch has been resolved.")
    func mainCheckoutLabelFallsBackToMain() {
        let entry = WorktreeEntry(path: "/repo", branch: "feature-x")
        let label = SidebarWorktreeLabel.text(
            for: entry,
            inRepoAtPath: "/repo",
            siblingPaths: ["/repo"],
            defaultBranch: nil
        )
        #expect(label == "main")
    }

    @Test func linkedWorktreeLabelIgnoresDefaultBranchArgument() {
        let entry = WorktreeEntry(path: "/repo/.worktrees/feature-x", branch: "feature/x")
        let label = SidebarWorktreeLabel.text(
            for: entry,
            inRepoAtPath: "/repo",
            siblingPaths: ["/repo", "/repo/.worktrees/feature-x"],
            defaultBranch: "trunk"
        )
        #expect(label == "feature-x")
    }

    @Test("managed nested worktree label preserves its full relative name")
    func managedNestedWorktreeLabelPreservesFullRelativeName() {
        let entry = WorktreeEntry(
            path: "/repo/.worktrees/research/lead",
            branch: "research/lead"
        )
        let label = SidebarWorktreeLabel.text(
            for: entry,
            inRepoAtPath: "/repo",
            siblingPaths: ["/repo", entry.path],
            defaultBranch: "main"
        )

        #expect(label == "research/lead")
    }

    @Test func mainCheckoutLabelDoesNotReadWorktreeBranch() {
        // Under the new design, the main-checkout label is the
        // resolved default branch, not the worktree's current branch.
        // A BIDI-override scalar in `entry.branch` cannot reach this
        // label at all. (The secondary caption in WorktreeRow.swift
        // still goes through `entry.displayBranch`, which strips
        // BIDI overrides per GIT-2.10.)
        let entry = WorktreeEntry(path: "/repo", branch: "feat\u{202E}lanigiro")
        let label = SidebarWorktreeLabel.text(
            for: entry,
            inRepoAtPath: "/repo",
            siblingPaths: ["/repo"],
            defaultBranch: "main"
        )
        #expect(label == "main")
    }

    @Test func repoLabelsMatchPerRowLabels() {
        let main = WorktreeEntry(path: "/repo", branch: "main")
        let nested = WorktreeEntry(path: "/repo/.worktrees/feature-x", branch: "feature/x")
        let sibling = WorktreeEntry(path: "/repo/.other/feature-x", branch: "feature/x-alt")
        let worktrees = [main, nested, sibling]

        let labels = SidebarWorktreeLabel.texts(
            for: worktrees,
            inRepoAtPath: "/repo",
            defaultBranch: "main"
        )
        let siblingPaths = worktrees.map(\.path)

        for worktree in worktrees {
            #expect(labels[worktree.id] == SidebarWorktreeLabel.text(
                for: worktree,
                inRepoAtPath: "/repo",
                siblingPaths: siblingPaths,
                defaultBranch: "main"
            ))
        }
    }
}
