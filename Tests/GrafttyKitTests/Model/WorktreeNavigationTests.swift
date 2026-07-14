import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

@Suite("KBD-5 worktree navigation — attention-first, else cyclic.")
struct WorktreeNavigationTests {

    // MARK: fixtures

    private func att() -> Attention {
        Attention(text: "needs input", timestamp: Date(timeIntervalSince1970: 1), source: .agentStop)
    }

    /// A worktree at `path`, optionally flagged with worktree-level attention,
    /// in a given state (default `.closed` = selectable/on-disk).
    private func wt(_ path: String, attention: Bool = false, state: WorktreeState = .closed) -> WorktreeEntry {
        WorktreeEntry(path: path, branch: "b", state: state, attention: attention ? att() : nil)
    }

    /// Single-repo AppState from the given worktrees + current selection.
    private func state(_ worktrees: [WorktreeEntry], selected: String?) -> AppState {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: worktrees)
        return AppState(repos: [repo], selectedWorktreePath: selected)
    }

    @Test("@spec KBD-5.1: When another on-disk worktree has attention, Ctrl+Option+Tab shall select the next attention-carrying worktree in cyclic sidebar order (skipping non-attention worktrees between), flattening worktrees across repos in sidebar order.")
    func forwardPrefersAttention() {
        // A(selected) B(no) C(attention) D(no) — skip B, land on C.
        let s = state([wt("/a"), wt("/b"), wt("/c", attention: true), wt("/d")], selected: "/a")
        #expect(s.nextWorktreePath(forward: true) == "/c")

        // Order flattens across repos: r1[/a,/b], r2[/c(attention)]; from /b -> /c.
        let repo1 = RepoEntry(path: "/r1", displayName: "r1", worktrees: [wt("/a"), wt("/b")])
        let repo2 = RepoEntry(path: "/r2", displayName: "r2", worktrees: [wt("/c", attention: true)])
        let crossRepo = AppState(repos: [repo1, repo2], selectedWorktreePath: "/b")
        #expect(crossRepo.nextWorktreePath(forward: true) == "/c")
    }

    @Test("@spec KBD-5.2: When no other worktree has attention, Ctrl+Option+Tab shall select the immediate next on-disk worktree in cyclic sidebar order, wrapping from the last back to the first.")
    func forwardPlainNextAndWrap() {
        let s = state([wt("/a"), wt("/b"), wt("/c")], selected: "/a")
        #expect(s.nextWorktreePath(forward: true) == "/b")

        let wrap = state([wt("/a"), wt("/b"), wt("/c")], selected: "/c")
        #expect(wrap.nextWorktreePath(forward: true) == "/a")
    }

    @Test("@spec KBD-5.3: When the user presses Ctrl+Option+Shift+Tab, the application shall apply attention-first selection in reverse cyclic order, and select the immediate previous on-disk worktree (wrapping) when no worktree has attention.")
    func reverseAttentionAndPlainWrap() {
        // A(attention) B(no) C(no) D(selected) — reverse to A.
        let attn = state([wt("/a", attention: true), wt("/b"), wt("/c"), wt("/d")], selected: "/d")
        #expect(attn.nextWorktreePath(forward: false) == "/a")

        // No attention, reverse from /a wraps to /c.
        let plain = state([wt("/a"), wt("/b"), wt("/c")], selected: "/a")
        #expect(plain.nextWorktreePath(forward: false) == "/c")
    }

    @Test("@spec KBD-5.4: When a worktree carries attention from any source (agent-stop, user notify, command-finished) at worktree or pane scope, the application shall count it as a navigation target, while excluding the currently-selected worktree from the attention subset so its own attention does not trap navigation on itself.")
    func attentionScopeAndCurrentExcluded() {
        // Pane-scoped attention counts the same as worktree-scoped.
        var b = wt("/b")
        b.paneAttention[PaneSlotID(id: UUID())] = att()
        let pane = state([wt("/a"), b, wt("/c")], selected: "/a")
        #expect(pane.nextWorktreePath(forward: true) == "/b")

        // Current selection with attention is excluded; forward goes to the other attention wt.
        let current = state([wt("/a", attention: true), wt("/b", attention: true), wt("/c")], selected: "/a")
        #expect(current.nextWorktreePath(forward: true) == "/b")

        // Each non-agentStop source counts the same as agentStop.
        func withSource(_ source: AttentionSource) -> AppState {
            var c = wt("/c")
            c.attention = Attention(text: "ping", timestamp: Date(timeIntervalSince1970: 2), source: source)
            return state([wt("/a"), wt("/b"), c], selected: "/a")
        }
        #expect(withSource(.userNotify).nextWorktreePath(forward: true) == "/c")
        #expect(withSource(.commandFinished).nextWorktreePath(forward: true) == "/c")
    }

    @Test("@spec KBD-5.5: When zero or one on-disk worktree is selectable, Ctrl+Option+Tab and Ctrl+Option+Shift+Tab shall be no-ops (return nil) while their chords remain reserved; non-on-disk worktrees (.stale/.creating/.deleting) shall never be navigation targets even when they carry attention.")
    func zeroOrOneSelectableNoOpAndSkipNonOnDisk() {
        let one = state([wt("/a")], selected: "/a")
        #expect(one.nextWorktreePath(forward: true) == nil)
        #expect(one.nextWorktreePath(forward: false) == nil)

        // A selectable + a non-on-disk sibling still counts as one selectable -> no-op.
        let plusStale = state([wt("/a"), wt("/s", attention: true, state: .stale)], selected: "/a")
        #expect(plusStale.nextWorktreePath(forward: true) == nil)

        // Non-on-disk worktree with attention is skipped -> land on the on-disk /c.
        let skip = state([wt("/a"), wt("/stale", attention: true, state: .stale), wt("/c")], selected: "/a")
        #expect(skip.nextWorktreePath(forward: true) == "/c")
    }

    @Test("@spec KBD-5.6: When no worktree is selected, Ctrl+Option+Tab shall select the first attention worktree else the first on-disk worktree, and Ctrl+Option+Shift+Tab shall select the first attention worktree scanning backward from the end else the last on-disk worktree.")
    func noSelectionEdges() {
        let plain = state([wt("/a"), wt("/b"), wt("/c")], selected: nil)
        #expect(plain.nextWorktreePath(forward: true) == "/a")
        #expect(plain.nextWorktreePath(forward: false) == "/c")

        // Attention-first applies with no selection, in both directions.
        let withAttn = state([wt("/a"), wt("/b", attention: true), wt("/c")], selected: nil)
        #expect(withAttn.nextWorktreePath(forward: true) == "/b")
        #expect(withAttn.nextWorktreePath(forward: false) == "/b")
    }
}
