import Testing
import Foundation
@testable import EspalierKit

@Suite("WorktreeEntry Tests")
struct WorktreeEntryTests {

    @Test func newEntryIsClosedState() {
        let entry = WorktreeEntry(path: "/tmp/worktree", branch: "feature/foo")
        #expect(entry.state == .closed)
        #expect(entry.attention == nil)
    }

    @Test func displayNameUsesLastComponentWhenUnique() {
        let main = WorktreeEntry(path: "/Users/ben/projects/myapp", branch: "main")
        let feature = WorktreeEntry(path: "/Users/ben/worktrees/myapp/feature-auth", branch: "feature/auth")
        let siblings = [main.path, feature.path]

        #expect(main.displayName(amongSiblingPaths: siblings) == "myapp")
        #expect(feature.displayName(amongSiblingPaths: siblings) == "feature-auth")
    }

    @Test func displayNameDisambiguatesCollisionsWithParent() {
        // Andy's actual dogfood state: two worktrees, both ending in the
        // repo name, but under different parent directories.
        let main = WorktreeEntry(path: "/Users/ben/projects/blindspots", branch: "main")
        let codex = WorktreeEntry(path: "/Users/ben/.codex/worktrees/6750/blindspots", branch: "(detached)")
        let siblings = [main.path, codex.path]

        #expect(main.displayName(amongSiblingPaths: siblings) == "projects/blindspots")
        #expect(codex.displayName(amongSiblingPaths: siblings) == "6750/blindspots")
    }

    @Test func displayNameFallsBackToBranchWhenPathIsEmpty() {
        let wt = WorktreeEntry(path: "", branch: "fallback-branch")
        #expect(wt.displayName(amongSiblingPaths: [""]) == "fallback-branch")
    }

    @Test func attentionCanBeSet() {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        entry.attention = Attention(text: "Build failed", timestamp: Date())
        #expect(entry.attention?.text == "Build failed")
    }

    @Test func attentionWithAutoClear() {
        let attn = Attention(text: "Done", timestamp: Date(), clearAfter: 10)
        #expect(attn.clearAfter == 10)
    }

    @Test func splitTreeDefaultsToNil() {
        let entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        #expect(entry.splitTree.root == nil)
    }

    @Test func codableRoundTrip() throws {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "feature/bar")
        entry.state = .running
        let id = TerminalID()
        entry.splitTree = SplitTree(root: .leaf(id))

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(WorktreeEntry.self, from: data)
        #expect(decoded.path == "/tmp/worktree")
        #expect(decoded.branch == "feature/bar")
        #expect(decoded.state == .running)
        #expect(decoded.splitTree.leafCount == 1)
    }

    @Test func repoEntryContainsWorktrees() {
        let main = WorktreeEntry(path: "/tmp/repo", branch: "main")
        let feature = WorktreeEntry(path: "/tmp/worktrees/feature", branch: "feature/x")
        let repo = RepoEntry(
            path: "/tmp/repo",
            displayName: "my-repo",
            worktrees: [main, feature]
        )
        #expect(repo.worktrees.count == 2)
        #expect(repo.displayName == "my-repo")
    }

    @Test func repoEntryCodeableRoundTrip() throws {
        let main = WorktreeEntry(path: "/tmp/repo", branch: "main")
        let repo = RepoEntry(path: "/tmp/repo", displayName: "my-repo", worktrees: [main])
        let data = try JSONEncoder().encode(repo)
        let decoded = try JSONDecoder().decode(RepoEntry.self, from: data)
        #expect(decoded.path == "/tmp/repo")
        #expect(decoded.worktrees.count == 1)
    }
}
