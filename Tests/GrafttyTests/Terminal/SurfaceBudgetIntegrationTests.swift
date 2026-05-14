import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("Surface budget integration (MEM-1.1 / MEM-1.3 / MEM-1.4)")
struct SurfaceBudgetIntegrationTests {

    /// Helper: build an AppState with N running worktrees, one leaf each,
    /// and return the leaf IDs by path so the test can assert against them.
    private func makeRunningState(paths: [String]) -> (AppState, [String: PaneSlotID]) {
        var leavesByPath: [String: PaneSlotID] = [:]
        let worktrees: [WorktreeEntry] = paths.map { path in
            let leaf = PaneSlotID()
            leavesByPath[path] = leaf
            var wt = WorktreeEntry(
                path: path,
                branch: (path as NSString).lastPathComponent,
                state: .running
            )
            wt.splitTree = SplitTree(root: .leaf(leaf))
            return wt
        }
        let state = AppState(
            repos: [RepoEntry(path: "/repo", displayName: "repo", worktrees: worktrees)],
            selectedWorktreePath: paths.first
        )
        return (state, leavesByPath)
    }

    @Test("""
@spec MEM-1.1: While more than 4 worktrees have live surfaces, the application shall evict the least-recently-selected worktree's surfaces.
""")
    func fifthSelectionEvictsFirstWorktree() {
        let paths = ["/a", "/b", "/c", "/d", "/e"]
        let (state, leaves) = makeRunningState(paths: paths)
        let manager = TerminalManager(socketPath: "/tmp/graftty-budget-test.sock")

        // Seed each leaf with metadata so we can verify preservation later.
        for (path, leaf) in leaves {
            manager.recordPaneSession(PaneSessionID(), for: leaf)
            _ = manager.recordTitle("title-\(path)", for: leaf)
        }

        for path in paths {
            manager.surfaceBudget.noteSelected(
                worktreePath: path,
                splitTreesByPath: state.runningSplitTreesByPath()
            )
        }

        // /a was the oldest — its leaf should be marked rehydrated.
        #expect(manager.wasRehydrated(leaves["/a"]!))
        // Others should not be marked rehydrated by the budget.
        for path in ["/b", "/c", "/d", "/e"] {
            #expect(!manager.wasRehydrated(leaves[path]!), "\(path) should not be rehydrated")
        }
    }

    @Test("""
@spec MEM-1.4: When a worktree whose surfaces were evicted is re-selected, the application shall re-create its surfaces via the same rehydration path used at cold launch.
""")
    func evictedWorktreePreservesMetadataForRehydration() {
        let paths = ["/a", "/b", "/c", "/d", "/e"]
        let (state, leaves) = makeRunningState(paths: paths)
        let manager = TerminalManager(socketPath: "/tmp/graftty-budget-test.sock")
        for (_, leaf) in leaves {
            manager.recordPaneSession(PaneSessionID(), for: leaf)
        }
        _ = manager.recordTitle("survives-eviction", for: leaves["/a"]!)
        _ = manager.recordPWD("/a/cwd", for: leaves["/a"]!)

        for path in paths {
            manager.surfaceBudget.noteSelected(
                worktreePath: path,
                splitTreesByPath: state.runningSplitTreesByPath()
            )
        }

        // After eviction, the metadata required for re-attach is still there.
        #expect(manager.wasRehydrated(leaves["/a"]!))
        #expect(manager.titles[leaves["/a"]!] == "survives-eviction")
        #expect(manager.pwds[leaves["/a"]!] == "/a/cwd")
        #expect(manager.zmxSessionName(for: leaves["/a"]!) != nil)
    }

    @Test("""
@spec MEM-1.3: When a worktree is stopped, removed, has its repo removed, or transitions to stale, the application shall drop it from the LRU budget.
""")
    func stoppedWorktreeIsPrunedOnNextNoteSelected() {
        let paths = ["/a", "/b", "/c", "/d"]
        var (state, _) = makeRunningState(paths: paths)
        let manager = TerminalManager(socketPath: "/tmp/graftty-budget-test.sock")

        // Fill the budget with four running worktrees.
        for path in paths {
            manager.surfaceBudget.noteSelected(
                worktreePath: path,
                splitTreesByPath: state.runningSplitTreesByPath()
            )
        }
        #expect(manager.surfaceBudget.lru == ["/d", "/c", "/b", "/a"])

        // Stop /a (transition to .closed) — it leaves the running set.
        state.repos[0].worktrees[0].state = .closed

        // Select a fifth running worktree. /a should be pruned out (not
        // counted) and /e should fit alongside /b /c /d without evicting
        // anyone — the running map only has four entries now.
        var newState = state
        let eLeaf = PaneSlotID()
        var eWt = WorktreeEntry(path: "/e", branch: "e", state: .running)
        eWt.splitTree = SplitTree(root: .leaf(eLeaf))
        newState.repos[0].worktrees.append(eWt)

        manager.surfaceBudget.noteSelected(
            worktreePath: "/e",
            splitTreesByPath: newState.runningSplitTreesByPath()
        )
        // /a is pruned; /e is head; /b /c /d remain. No evictions fired.
        #expect(manager.surfaceBudget.lru == ["/e", "/d", "/c", "/b"])
    }
}
