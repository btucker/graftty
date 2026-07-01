import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

@Suite("@spec KBD-5: ctrl+tab / ctrl+shift+tab worktree navigation — attention-first, else cyclic.")
struct WorktreeNavigationTests {

    // MARK: fixtures

    private func att() -> Attention {
        Attention(text: "needs input", timestamp: Date(timeIntervalSince1970: 1), source: .agentStop)
    }

    /// A worktree at `path`, optionally flagged with worktree-level attention,
    /// in a given on-disk-affecting state (default `.closed` = selectable).
    private func wt(_ path: String, attention: Bool = false, state: WorktreeState = .closed) -> WorktreeEntry {
        WorktreeEntry(path: path, branch: "b", state: state, attention: attention ? att() : nil)
    }

    /// Single-repo AppState from the given worktrees + current selection.
    private func state(_ worktrees: [WorktreeEntry], selected: String?) -> AppState {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: worktrees)
        return AppState(repos: [repo], selectedWorktreePath: selected)
    }

    // MARK: KBD-5.1 — attention worktree wins over plain next

    @Test("@spec KBD-5.1: When another on-disk worktree has attention, next_tab shall select the next attention-carrying worktree in cyclic sidebar order, skipping non-attention worktrees in between.")
    func forwardPrefersAttention() {
        // A(selected) B(no) C(attention) D(no)
        let s = state([wt("/a"), wt("/b"), wt("/c", attention: true), wt("/d")], selected: "/a")
        #expect(s.nextWorktreePath(forward: true) == "/c")
    }

    // MARK: KBD-5.2 — no attention anywhere → plain cyclic next

    @Test("@spec KBD-5.2: When no other worktree has attention, next_tab shall select the immediate next on-disk worktree in cyclic sidebar order.")
    func forwardPlainNext() {
        let s = state([wt("/a"), wt("/b"), wt("/c")], selected: "/a")
        #expect(s.nextWorktreePath(forward: true) == "/b")
    }

    @Test("@spec KBD-5.2: next_tab shall wrap from the last on-disk worktree back to the first when no worktree has attention.")
    func forwardWrapsAround() {
        let s = state([wt("/a"), wt("/b"), wt("/c")], selected: "/c")
        #expect(s.nextWorktreePath(forward: true) == "/a")
    }

    // MARK: KBD-5.3 — reverse

    @Test("@spec KBD-5.3: previous_tab shall apply attention-first selection in reverse cyclic order.")
    func reversePrefersAttention() {
        // A(attention) B(no) C(no) D(selected)
        let s = state([wt("/a", attention: true), wt("/b"), wt("/c"), wt("/d")], selected: "/d")
        #expect(s.nextWorktreePath(forward: false) == "/a")
    }

    @Test("@spec KBD-5.3: previous_tab shall select the immediate previous on-disk worktree (wrapping) when no worktree has attention.")
    func reversePlainPrevWraps() {
        let s = state([wt("/a"), wt("/b"), wt("/c")], selected: "/a")
        #expect(s.nextWorktreePath(forward: false) == "/c")
    }

    // MARK: KBD-5.4 — attention scope + current-excluded

    @Test("@spec KBD-5.4: Pane-scoped attention shall make a worktree a navigation target the same as worktree-scoped attention.")
    func paneAttentionCounts() {
        var b = wt("/b")
        b.paneAttention[PaneSlotID(id: UUID())] = att()
        let s = state([wt("/a"), b, wt("/c")], selected: "/a")
        #expect(s.nextWorktreePath(forward: true) == "/b")
    }

    @Test("@spec KBD-5.4: The currently-selected worktree shall be excluded from the attention subset, so its own attention does not trap navigation on itself.")
    func currentWithAttentionIsExcluded() {
        // A is selected AND has attention; B has attention. Forward must go to B, not stay on A.
        let s = state([wt("/a", attention: true), wt("/b", attention: true), wt("/c")], selected: "/a")
        #expect(s.nextWorktreePath(forward: true) == "/b")
    }

    @Test("@spec KBD-5.4: A userNotify or commandFinished attention source shall count the same as agentStop for navigation.")
    func anyAttentionSourceCounts() {
        let notify = Attention(text: "ping", timestamp: Date(timeIntervalSince1970: 2), source: .userNotify)
        var c = wt("/c")
        c.attention = notify
        let s = state([wt("/a"), wt("/b"), c], selected: "/a")
        #expect(s.nextWorktreePath(forward: true) == "/c")
    }

    // MARK: KBD-5.5 — 0/1 selectable → no-op

    @Test("@spec KBD-5.5: When zero or one on-disk worktree is selectable, next_tab and previous_tab shall be a no-op (return nil).")
    func oneOrZeroSelectableIsNoOp() {
        let one = state([wt("/a")], selected: "/a")
        #expect(one.nextWorktreePath(forward: true) == nil)
        #expect(one.nextWorktreePath(forward: false) == nil)

        // A selectable + a non-on-disk sibling still counts as one selectable.
        let plusStale = state([wt("/a"), wt("/s", attention: true, state: .stale)], selected: "/a")
        #expect(plusStale.nextWorktreePath(forward: true) == nil)
    }

    @Test("@spec KBD-5.5: Non-on-disk worktrees (.stale/.creating/.deleting) shall never be navigation targets, even when they carry attention.")
    func skipsNonOnDiskWorktrees() {
        // A(selected) STALE(attention) C(no). Stale must be skipped → land on C.
        let s = state([wt("/a"), wt("/stale", attention: true, state: .stale), wt("/c")], selected: "/a")
        #expect(s.nextWorktreePath(forward: true) == "/c")
    }

    // MARK: KBD-5.6 — no selection

    @Test("@spec KBD-5.6: When no worktree is selected, next_tab shall select the first attention worktree, else the first on-disk worktree; previous_tab shall select the last.")
    func noSelectionStartsAtEdges() {
        let plain = state([wt("/a"), wt("/b"), wt("/c")], selected: nil)
        #expect(plain.nextWorktreePath(forward: true) == "/a")
        #expect(plain.nextWorktreePath(forward: false) == "/c")

        let withAttn = state([wt("/a"), wt("/b", attention: true), wt("/c")], selected: nil)
        #expect(withAttn.nextWorktreePath(forward: true) == "/b")
    }

    // MARK: cross-repo ordering

    @Test("@spec KBD-5.1: Navigation order shall flatten worktrees across repos in sidebar order (repo order, then worktree order).")
    func flattensAcrossRepos() {
        let repo1 = RepoEntry(path: "/r1", displayName: "r1", worktrees: [wt("/a"), wt("/b")])
        let repo2 = RepoEntry(path: "/r2", displayName: "r2", worktrees: [wt("/c", attention: true)])
        let s = AppState(repos: [repo1, repo2], selectedWorktreePath: "/b")
        #expect(s.nextWorktreePath(forward: true) == "/c")
    }
}
