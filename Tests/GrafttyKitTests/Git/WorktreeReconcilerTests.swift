import Testing
import Foundation
@testable import GrafttyKit

@Suite("WorktreeReconciler", .serialized)
struct WorktreeReconcilerTests {

    func wt(_ path: String, _ branch: String, state: WorktreeState = .closed) -> WorktreeEntry {
        var e = WorktreeEntry(path: path, branch: branch, state: state)
        e.state = state
        return e
    }

    @Test func newlyDiscoveredPathIsAdded() {
        let r = WorktreeReconciler.reconcile(
            existing: [],
            discovered: [DiscoveredWorktree(path: "/r/a", branch: "main")]
        )
        #expect(r.merged.count == 1)
        #expect(r.newlyAdded.count == 1)
        #expect(r.merged[0].state == .closed)
        #expect(r.merged[0].branch == "main")
    }

    @Test func missingPathTransitionsToStale() {
        let existing = [wt("/r/gone", "feat", state: .closed)]
        let r = WorktreeReconciler.reconcile(existing: existing, discovered: [])
        #expect(r.merged[0].state == .stale)
        #expect(r.newlyStale.count == 1)
        #expect(r.newlyStale[0].path == "/r/gone")
    }

    @Test func newlyStaleEntriesMoveAfterNonStaleSiblings() {
        let existing = [
            wt("/r/gone-a", "gone-a", state: .closed),
            wt("/r/live-a", "live-a", state: .running),
            wt("/r/gone-b", "gone-b", state: .closed),
            wt("/r/live-b", "live-b", state: .closed),
        ]
        let discovered = [
            DiscoveredWorktree(path: "/r/live-a", branch: "live-a"),
            DiscoveredWorktree(path: "/r/live-b", branch: "live-b"),
        ]

        let r = WorktreeReconciler.reconcile(existing: existing, discovered: discovered)

        #expect(r.merged.map(\.branch) == ["live-a", "live-b", "gone-a", "gone-b"])
        #expect(r.merged.suffix(2).allSatisfy { $0.state == .stale })
    }

    @Test func alreadyStaleIsNotCountedAsNewlyStale() {
        let existing = [wt("/r/gone", "feat", state: .stale)]
        let r = WorktreeReconciler.reconcile(existing: existing, discovered: [])
        #expect(r.merged[0].state == .stale)
        #expect(r.newlyStale.isEmpty, "stale → stale is not a transition")
    }

    @Test func reappearingStaleEntryResurrectsToClosed() {
        // The observed bug: worktrees got stuck stale because no path
        // transitioned them back. Cycles 23 etc. assumed stale entries
        // meant "really gone" — but a transient FSEvents glitch, a
        // `git worktree repair`, or a force-remove+re-add at the same
        // path can all put a stale entry back in git's view.
        let existing = [wt("/r/back", "feat", state: .stale)]
        let discovered = [DiscoveredWorktree(path: "/r/back", branch: "feat")]
        let r = WorktreeReconciler.reconcile(existing: existing, discovered: discovered)
        #expect(r.merged[0].state == .closed)
        #expect(r.resurrected.count == 1)
        #expect(r.resurrected[0].path == "/r/back")
    }

    @Test func resurrectionAdoptsLatestBranch() {
        // If the worktree was re-added on a different branch while
        // stale, honor the new branch label.
        let existing = [wt("/r/back", "old-branch", state: .stale)]
        let discovered = [DiscoveredWorktree(path: "/r/back", branch: "new-branch")]
        let r = WorktreeReconciler.reconcile(existing: existing, discovered: discovered)
        #expect(r.merged[0].branch == "new-branch")
    }

    @Test func liveEntryAdoptsLatestBranchWithoutStateChange() {
        let existing = [wt("/r/a", "main", state: .running)]
        let discovered = [DiscoveredWorktree(path: "/r/a", branch: "feature/x")]
        let r = WorktreeReconciler.reconcile(existing: existing, discovered: discovered)
        #expect(r.merged[0].state == .running) // preserved
        #expect(r.merged[0].branch == "feature/x") // updated
        #expect(r.resurrected.isEmpty)
        #expect(r.newlyStale.isEmpty)
    }

    /// GIT-5.8: a `.creating` placeholder is in flight by definition —
    /// `git worktree add` hasn't finished writing the admin entry yet,
    /// so an FSEvents-driven reconcile must NOT flip it to `.stale`.
    /// Only `AddWorktreeFlow` is allowed to clear placeholders.
    @Test("""
    @spec GIT-5.8: While a worktree entry is in the `.creating` state, the reconciler (`WorktreeReconciler.reconcile`) shall not transition the entry to `.stale` even when the path is absent from `git worktree list --porcelain` output. The placeholder is in flight by definition — git hasn't finished writing its admin entry yet — and only `AddWorktreeFlow` is permitted to clear the placeholder (success → `.running`, failure → remove). Without this guard, an FSEvents tick on `.git/worktrees/` that fires before git's admin write completes (or one driven by an unrelated change in another worktree) would briefly flash the spinning placeholder to `.stale`.
    """)
    func creatingPlaceholderIsPreservedWhenAbsentFromDiscovery() {
        let existing = [wt("/r/in-flight", "feat", state: .creating)]
        let r = WorktreeReconciler.reconcile(existing: existing, discovered: [])
        #expect(r.merged[0].state == .creating,
                "placeholder must not be transitioned to .stale by the reconciler")
        #expect(r.newlyStale.isEmpty)
    }

    /// Once git finishes and the path appears in porcelain, the
    /// reconciler should NOT promote the placeholder to `.closed` —
    /// `AddWorktreeFlow.finishCreate` owns the `.creating → .running`
    /// transition. Branch label adoption is fine (the `else` arm of
    /// the existing reconcile loop already handles that for any
    /// non-stale state).
    @Test func creatingPlaceholderRetainsStateWhenDiscovered() {
        let existing = [wt("/r/in-flight", "old-name", state: .creating)]
        let discovered = [DiscoveredWorktree(path: "/r/in-flight", branch: "real-name")]
        let r = WorktreeReconciler.reconcile(existing: existing, discovered: discovered)
        #expect(r.merged[0].state == .creating)
        #expect(r.merged[0].branch == "real-name", "branch label adoption still applies")
        #expect(r.resurrected.isEmpty, ".creating is not a stale-resurrect")
        #expect(r.newlyAdded.isEmpty, "placeholder is not double-added")
    }

    /// GIT-4.18: a `.deleting` placeholder is in flight by definition —
    /// `git worktree remove` is mid-call. If the remove succeeds the
    /// worktree directory and the git admin entry both disappear in
    /// quick succession; an FSEvents-driven reconcile that fires before
    /// `DeleteWorktreeFlow` removes the model entry must NOT flip the
    /// spinning row to `.stale`. Only `DeleteWorktreeFlow` is allowed to
    /// clear `.deleting` placeholders (success → remove from model,
    /// failure → restore prior state).
    @Test("""
    @spec GIT-4.18: While a worktree entry is in the `.deleting` state, the reconciler (`WorktreeReconciler.reconcile`) shall not transition the entry to `.stale` even when the path is absent from `git worktree list --porcelain` output. The placeholder is in flight by definition — `git worktree remove` is mid-call and the admin entry may disappear from porcelain before `DeleteWorktreeFlow` removes the model entry — and only `DeleteWorktreeFlow` is permitted to clear the placeholder (success → remove from model, failure → restore prior state). Mirrors `GIT-5.8` for `.creating`.
    """)
    func deletingPlaceholderIsPreservedWhenAbsentFromDiscovery() {
        let existing = [wt("/r/in-flight", "feat", state: .deleting)]
        let r = WorktreeReconciler.reconcile(existing: existing, discovered: [])
        #expect(r.merged[0].state == .deleting,
                "placeholder must not be transitioned to .stale by the reconciler")
        #expect(r.newlyStale.isEmpty)
    }

    @Test func mixedSet() {
        let existing = [
            wt("/r/a", "main", state: .running), // stays
            wt("/r/b", "feat", state: .closed),  // goes stale
            wt("/r/c", "dev",  state: .stale),   // resurrects
        ]
        let discovered = [
            DiscoveredWorktree(path: "/r/a", branch: "main"),
            DiscoveredWorktree(path: "/r/c", branch: "dev"),
            DiscoveredWorktree(path: "/r/d", branch: "new"), // new
        ]
        let r = WorktreeReconciler.reconcile(existing: existing, discovered: discovered)
        #expect(r.merged.count == 4)
        #expect(r.merged.first(where: { $0.path == "/r/a" })?.state == .running)
        #expect(r.merged.first(where: { $0.path == "/r/b" })?.state == .stale)
        #expect(r.merged.first(where: { $0.path == "/r/c" })?.state == .closed)
        #expect(r.merged.first(where: { $0.path == "/r/d" })?.state == .closed)
        #expect(r.newlyAdded.map(\.path) == ["/r/d"])
        #expect(r.newlyStale.map(\.path) == ["/r/b"])
        #expect(r.resurrected.map(\.path) == ["/r/c"])
    }
}
