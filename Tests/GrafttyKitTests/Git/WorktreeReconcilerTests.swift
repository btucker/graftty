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
