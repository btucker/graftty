import Testing
import Foundation
@testable import GrafttyKit

@Suite("WorktreeEntry Tests", .serialized)
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

    /// LAYOUT-2.15: 1-level parent disambiguation still collides when
    /// two worktrees share BOTH their leaf AND their immediate parent.
    /// Common under `git worktree add -B team/member/feature` style
    /// layouts where `WorktreeNameSanitizer` allows `/` (GIT-5.1) — the
    /// resulting worktree dir is `.worktrees/team/member/feature`, and
    /// two such paths from different roots share "member/feature".
    /// Recurse until the suffix is unique.
    @Test func displayNameDisambiguatesThreeLevelCollision() {
        let a = WorktreeEntry(path: "/repo/.worktrees/deep/ns/feature", branch: "ns/feature")
        let b = WorktreeEntry(path: "/repo/.worktrees/other/ns/feature", branch: "ns/feature")
        let siblings = [a.path, b.path]

        // Before the fix, BOTH return "ns/feature" (ambiguous).
        #expect(a.displayName(amongSiblingPaths: siblings) == "deep/ns/feature")
        #expect(b.displayName(amongSiblingPaths: siblings) == "other/ns/feature")
    }

    @Test func displayNameFallsThroughWhenAllPathsShareSuffix() {
        // Pathological: one sibling's path is a strict suffix of another
        // (impossible in git but defensive). The longer path should fall
        // through to its full form; the shorter one takes what it has.
        let shorter = WorktreeEntry(path: "/a/b/c", branch: "x")
        let longer = WorktreeEntry(path: "/z/a/b/c", branch: "x")
        let siblings = [shorter.path, longer.path]

        // Shorter path has 3 components; at suffixLen=3 candidate is
        // "a/b/c", longer's suffixLen=3 is "a/b/c" — collide. Shorter
        // has exhausted its components, so falls back to full path.
        // Longer at suffixLen=4 becomes "z/a/b/c" — unique.
        #expect(shorter.displayName(amongSiblingPaths: siblings) == "/a/b/c")
        #expect(longer.displayName(amongSiblingPaths: siblings) == "z/a/b/c")
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
    // `graftty notify --clear-after 10 "A"` schedules a clear at t=10.
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
    // CLI `graftty notify` is worktree-targeted and stays on the
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

    @Test func offeredDeleteForMergedPRDefaultsToNil() {
        let entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        #expect(entry.offeredDeleteForMergedPR == nil)
    }

    @Test func offeredDeleteForMergedPRSurvivesCodableRoundTrip() throws {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        entry.offeredDeleteForMergedPR = 123
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(WorktreeEntry.self, from: data)
        #expect(decoded.offeredDeleteForMergedPR == 123)
    }

    @Test func decodesLegacyStateWithoutOfferedDeleteField() throws {
        // Same backwards-compat rule as `paneAttention` above: pre-fix
        // state.json blobs don't carry the new key. Decode must default
        // it to nil rather than throw and wipe the user's saved state.
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
        #expect(decoded.offeredDeleteForMergedPR == nil)
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

    // MARK: resurrect-from-stale contract (GIT-3.9)
    //
    // When a .stale entry is resurrected (directory still on disk), its
    // old leaf TerminalIDs point at surfaces that are now orphan — the
    // resurrect path creates a *fresh* terminal with a *new* TerminalID.
    // The surfaces behind the old IDs keep running render/io/kqueue
    // threads, and on macOS that's been observed to corrupt libghostty's
    // internal `os_unfair_lock` during window resize and SIGKILL the app.
    //
    // `prepareForResurrection()` returns the leaves the caller must
    // destroy, then transitions the entry into a clean .closed state with
    // no split tree, no focused terminal, and no pane attention. If the
    // caller fails to destroy those leaves, the next resurrection leaks
    // more surfaces — this is an invariant worth enforcing in the type.

    @Test func prepareForResurrectionReturnsOldLeavesToDestroy() {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        let leaf1 = TerminalID()
        let leaf2 = TerminalID()
        entry.splitTree = SplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(leaf1),
            right: .leaf(leaf2)
        )))
        entry.state = .stale
        entry.focusedTerminalID = leaf1
        entry.paneAttention[leaf1] = Attention(text: "!", timestamp: Date())

        let toDestroy = entry.prepareForResurrection()

        #expect(Set(toDestroy) == Set([leaf1, leaf2]))
        #expect(entry.state == .closed)
        #expect(entry.splitTree.root == nil)
        #expect(entry.focusedTerminalID == nil)
        #expect(entry.paneAttention.isEmpty)
    }

    @Test func prepareForResurrectionReturnsEmptyWhenNoLeaves() {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        entry.state = .stale

        let toDestroy = entry.prepareForResurrection()

        #expect(toDestroy.isEmpty)
        #expect(entry.state == .closed)
    }

    // MARK: Dismiss-from-stale teardown (GIT-3.10)
    //
    // `GIT-3.4` keeps terminal surfaces alive when a worktree goes stale-
    // while-running. If the user then right-clicks → Dismiss, the old
    // pre-fix `dismissWorktree` path removed the entry from the model
    // but NEVER called `TerminalManager.destroySurfaces` — leaving
    // render/io/kqueue threads running for panes no longer visible
    // anywhere. Same orphan-surfaces class as the GIT-3.9 resurrect
    // path; same crash signature (`os_unfair_lock` corruption under
    // window resize).
    //
    // `prepareForDismissal()` returns the leaves the caller MUST tear
    // down and atomically clears the entry's split tree / focus /
    // paneAttention so silently-leak shape is no longer spellable.

    @Test func prepareForDismissalReturnsOldLeavesToDestroy() {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        let leafA = TerminalID()
        let leafB = TerminalID()
        entry.splitTree = SplitTree(root: .split(.init(
            direction: .vertical,
            ratio: 0.5,
            left: .leaf(leafA),
            right: .leaf(leafB)
        )))
        entry.state = .stale
        entry.focusedTerminalID = leafA
        entry.paneAttention[leafA] = Attention(text: "!", timestamp: Date())

        let toDestroy = entry.prepareForDismissal()

        #expect(Set(toDestroy) == Set([leafA, leafB]))
        #expect(entry.splitTree.root == nil)
        #expect(entry.focusedTerminalID == nil)
        #expect(entry.paneAttention.isEmpty)
    }

    @Test func prepareForDismissalOnEmptyTreeReturnsEmpty() {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        entry.state = .stale

        let toDestroy = entry.prepareForDismissal()

        #expect(toDestroy.isEmpty)
    }

    // MARK: Stop-worktree teardown (STATE-2.11)
    //
    // The Stop menu action destroys every pane's surface at once. The
    // pre-fix `stopWorktreeWithConfirmation` set `state = .closed` but
    // LEFT `paneAttention` untouched. Because Stop preserves `splitTree`
    // (so re-open recreates the same layout per TERM-1.2), the old leaf
    // TerminalIDs stay — which means a stale pane attention badge from
    // *before* the Stop reappears on the fresh pane's sidebar row after
    // re-open. STATE-2.7's spirit (pane removal drops pane-scoped
    // attention) extended here: Stop removes all panes; all entries
    // must go.
    //
    // `prepareForStop()` transitions state → .closed, clears
    // paneAttention, leaves splitTree + focusedTerminalID + the
    // worktree-level `attention` slot alone so the closed→running
    // re-open block can recreate the exact layout and the user still
    // sees any CLI-notify badge (which is a worktree-level concern).

    @Test func prepareForStopClearsPaneAttentionAndClosesState() {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        let paneA = TerminalID()
        let paneB = TerminalID()
        entry.state = .running
        entry.splitTree = SplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(paneA),
            right: .leaf(paneB)
        )))
        entry.focusedTerminalID = paneA
        entry.paneAttention[paneA] = Attention(text: "✓", timestamp: Date())
        entry.paneAttention[paneB] = Attention(text: "!", timestamp: Date())

        entry.prepareForStop()

        #expect(entry.state == .closed)
        #expect(entry.paneAttention.isEmpty)
    }

    @Test func prepareForStopPreservesSplitTreeAndFocusedTerminalID() {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        let paneA = TerminalID()
        entry.state = .running
        entry.splitTree = SplitTree(root: .leaf(paneA))
        entry.focusedTerminalID = paneA

        entry.prepareForStop()

        // TERM-1.2: re-open after Stop recreates the same layout.
        #expect(entry.splitTree.allLeaves == [paneA])
        #expect(entry.focusedTerminalID == paneA)
    }

    @Test func prepareForStopPreservesWorktreeLevelAttention() {
        // STATE-2.5 / ATTN-1.x: Stop leaves the CLI-notify (worktree-level)
        // slot alone. A user who `graftty notify`'d then Stop'd should see
        // the badge again when they re-open.
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        entry.state = .running
        entry.attention = Attention(text: "Build failed", timestamp: Date())

        entry.prepareForStop()

        #expect(entry.attention?.text == "Build failed")
    }

    // MARK: focus-after-pane-close (TERM-5.6)
    //
    // Pre-fix, `closePane` unconditionally reset `focusedTerminalID`
    // to `newTree.allLeaves.first` whenever the tree wasn't empty —
    // even when the CLOSED pane wasn't the focused one. So a user
    // typing in pane C who closed pane A via Cmd+W (or `graftty pane
    // close 1`) would silently lose focus to pane B (= newTree's first
    // leaf), with no user action that should cause focus to move.
    // Matches Andy's explicit pain: "Furious when any tool kills a
    // long-running shell unexpectedly" — the logical equivalent for
    // focus is "silently redirecting my typing to a different pane."
    //
    // The rule codified by `focusAfterRemoving`: the closed pane is
    // the only one that needs a new home. If someone else was focused,
    // leave that focus alone.

    @Test func focusAfterRemovingKeepsSurvivorFocusWhenDifferentPaneClosed() {
        let a = TerminalID()
        let b = TerminalID()
        let c = TerminalID()
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal, ratio: 0.5,
            left: .leaf(a),
            right: .split(.init(
                direction: .horizontal, ratio: 0.5,
                left: .leaf(b),
                right: .leaf(c)
            ))
        )))
        let newTree = tree.removing(a)

        // User was focused on C; they closed A. Focus stays on C.
        let newFocus = SplitTree.focusAfterRemoving(
            currentFocus: c,
            removed: a,
            remainingTree: newTree
        )
        #expect(newFocus == c)
    }

    @Test func focusAfterRemovingPromotesWhenClosedWasFocused() {
        let a = TerminalID()
        let b = TerminalID()
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal, ratio: 0.5,
            left: .leaf(a),
            right: .leaf(b)
        )))
        let newTree = tree.removing(a)

        // User was focused on A and closed A. Promote to the survivor.
        let newFocus = SplitTree.focusAfterRemoving(
            currentFocus: a,
            removed: a,
            remainingTree: newTree
        )
        #expect(newFocus == b)
    }

    @Test func focusAfterRemovingReturnsNilWhenTreeIsEmpty() {
        let a = TerminalID()
        let emptyTree = SplitTree(root: nil)

        let newFocus = SplitTree.focusAfterRemoving(
            currentFocus: a,
            removed: a,
            remainingTree: emptyTree
        )
        #expect(newFocus == nil)
    }

    @Test func focusAfterRemovingReturnsNilWhenCurrentFocusWasNil() {
        // Worktree was just resurrected / stopped — no focus yet.
        let a = TerminalID()
        let b = TerminalID()
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal, ratio: 0.5,
            left: .leaf(a),
            right: .leaf(b)
        )))
        let newTree = tree.removing(a)

        let newFocus = SplitTree.focusAfterRemoving(
            currentFocus: nil,
            removed: a,
            remainingTree: newTree
        )
        #expect(newFocus == nil)
    }

    /// Branch names can contain Unicode bidirectional-override scalars
    /// — git accepts most Unicode in ref names, and a collaborator (or
    /// compromised account) with push access can ship a branch named
    /// `feat\u{202E}lanigiro` which renders RTL-reversed in the
    /// breadcrumb and sidebar. Same Trojan Source visual deception
    /// (CVE-2021-42574) that `PR-5.5` blocks for PR titles; the
    /// branch name comes from external data too, so strip (don't
    /// reject). `wt.branch` stays raw so `git` / `gh pr list` can use
    /// the real ref; `wt.displayBranch` is the sanitized version the
    /// render sites read.
    @Test func displayBranchStripsBidiOverrides() {
        let entry = WorktreeEntry(path: "/p", branch: "feat\u{202E}lanigiro")
        #expect(entry.branch == "feat\u{202E}lanigiro",
                "raw branch must be preserved for git operations")
        #expect(entry.displayBranch == "featlanigiro")
    }

    @Test func displayBranchUnchangedForRegularNames() {
        #expect(WorktreeEntry(path: "/p", branch: "main").displayBranch == "main")
        #expect(WorktreeEntry(path: "/p", branch: "feat/new-ui").displayBranch == "feat/new-ui")
    }
}
