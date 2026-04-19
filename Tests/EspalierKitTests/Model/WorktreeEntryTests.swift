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

    // MARK: auto-clear timestamp guard
    //
    // `espalier notify --clear-after 10 "A"` schedules a clear at t=10.
    // If a second `notify "B"` lands at t=5, the pending timer must NOT
    // wipe "B" when it fires — the auto-clear is for *its own*
    // notification, not the current one. Server code captures the
    // Attention's timestamp when scheduling and uses
    // `clearAttentionIfTimestamp(_:)` to guard the fire.

    @Test func clearAttentionIfTimestampClearsMatching() {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        let now = Date()
        entry.attention = Attention(text: "A", timestamp: now, clearAfter: 10)
        entry.clearAttentionIfTimestamp(now)
        #expect(entry.attention == nil)
    }

    @Test func clearAttentionIfTimestampIsNoopForReplacedAttention() {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        let t1 = Date()
        entry.attention = Attention(text: "A", timestamp: t1, clearAfter: 10)
        let t2 = t1.addingTimeInterval(5)
        entry.attention = Attention(text: "B", timestamp: t2)

        // Timer scheduled by "A" fires at t=10, but the current attention
        // is "B" — the guard must keep "B" alive.
        entry.clearAttentionIfTimestamp(t1)
        #expect(entry.attention?.text == "B")
    }

    @Test func clearAttentionIfTimestampIsNoopWhenAlreadyCleared() {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        let now = Date()
        entry.attention = Attention(text: "A", timestamp: now, clearAfter: 10)
        entry.attention = nil
        entry.clearAttentionIfTimestamp(now) // should not crash or re-set
        #expect(entry.attention == nil)
    }

    // MARK: pane-scoped auto-clear timestamp guard
    //
    // Same STATE-2.6 story for pane-scoped attention (shell-integration
    // pings): a pending auto-clear timer must only fire if the currently
    // stored attention for that specific pane still has the timestamp
    // captured when the timer was scheduled.

    @Test func clearPaneAttentionIfTimestampClearsMatching() {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        let pane = TerminalID()
        let now = Date()
        entry.paneAttention[pane] = Attention(text: "A", timestamp: now, clearAfter: 3)
        entry.clearPaneAttentionIfTimestamp(now, for: pane)
        #expect(entry.paneAttention[pane] == nil)
    }

    @Test func clearPaneAttentionIfTimestampIsNoopForReplaced() {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        let pane = TerminalID()
        let t1 = Date()
        entry.paneAttention[pane] = Attention(text: "A", timestamp: t1, clearAfter: 10)
        let t2 = t1.addingTimeInterval(1)
        entry.paneAttention[pane] = Attention(text: "B", timestamp: t2)

        // The timer scheduled by "A" fires at t=10; "B" is current
        // at that time. Guard keeps "B" alive.
        entry.clearPaneAttentionIfTimestamp(t1, for: pane)
        #expect(entry.paneAttention[pane]?.text == "B")
    }

    @Test func clearPaneAttentionIfTimestampDoesNotAffectSiblings() {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        let pane1 = TerminalID()
        let pane2 = TerminalID()
        let t = Date()
        entry.paneAttention[pane1] = Attention(text: "A", timestamp: t, clearAfter: 3)
        entry.paneAttention[pane2] = Attention(text: "B", timestamp: t, clearAfter: 3)
        entry.clearPaneAttentionIfTimestamp(t, for: pane1)
        #expect(entry.paneAttention[pane1] == nil)
        #expect(entry.paneAttention[pane2]?.text == "B")
    }

    @Test func clearPaneAttentionIfTimestampIsNoopWhenAlreadyCleared() {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        let pane = TerminalID()
        let now = Date()
        entry.paneAttention[pane] = Attention(text: "A", timestamp: now, clearAfter: 5)
        entry.paneAttention[pane] = nil
        entry.clearPaneAttentionIfTimestamp(now, for: pane)
        #expect(entry.paneAttention[pane] == nil)
    }

    // MARK: paneAttention
    //
    // Per-pane attention badges are distinct from the worktree-level
    // `attention` slot. Shell-integration events (command-finished) are
    // emitted by a specific pane and must land on that pane's row only;
    // CLI `espalier notify` is worktree-targeted and stays on the
    // worktree-level slot. Pane rows render pane-level when present and
    // fall back to worktree-level otherwise — so both code paths keep
    // working without stepping on each other.

    @Test func paneAttentionDefaultsToEmpty() {
        let entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        #expect(entry.paneAttention.isEmpty)
    }

    @Test func settingOnePaneDoesNotAffectOtherPanesOrWorktreeSlot() {
        // The reported bug in plain model form: two panes in one
        // worktree, a command-finished ping lands on pane A, and pane B
        // plus the worktree-level `attention` slot must stay untouched.
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        let paneA = TerminalID()
        let paneB = TerminalID()
        entry.paneAttention[paneA] = Attention(text: "✓", timestamp: Date(), clearAfter: 3)
        #expect(entry.paneAttention[paneA]?.text == "✓")
        #expect(entry.paneAttention[paneB] == nil)
        #expect(entry.attention == nil)
    }

    @Test func paneAttentionCodableRoundTrip() throws {
        // Per-pane attention is ephemeral (auto-clears in 3–8s) but we
        // round-trip through Codable anyway so it travels with the rest
        // of AppState's persisted shape without special-casing.
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        let paneA = TerminalID()
        entry.paneAttention[paneA] = Attention(text: "!", timestamp: Date(), clearAfter: 8)

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(WorktreeEntry.self, from: data)
        #expect(decoded.paneAttention[paneA]?.text == "!")
    }

    @Test func decodesLegacyStateWithoutPaneAttentionField() throws {
        // Existing users have WorktreeEntry blobs on disk from pre-fix
        // releases that don't have the `paneAttention` key. Decode must
        // tolerate the missing field rather than wiping the whole saved
        // tree — we default it to empty and move on.
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "path": "/tmp/worktree",
          "branch": "main",
          "state": "closed",
          "splitTree": {"root": null}
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(WorktreeEntry.self, from: data)
        #expect(decoded.paneAttention.isEmpty)
        #expect(decoded.attention == nil)
        #expect(decoded.path == "/tmp/worktree")
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
