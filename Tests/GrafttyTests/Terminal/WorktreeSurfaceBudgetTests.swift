import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("WorktreeSurfaceBudget — LRU semantics")
struct WorktreeSurfaceBudgetTests {

    /// Helper: build a `[String: SplitTree]` snapshot with one leaf per path.
    private func singleLeafTrees(_ paths: [String]) -> ([String: SplitTree], [String: PaneSlotID]) {
        var trees: [String: SplitTree] = [:]
        var leaves: [String: PaneSlotID] = [:]
        for path in paths {
            let leaf = PaneSlotID()
            leaves[path] = leaf
            trees[path] = SplitTree(root: .leaf(leaf))
        }
        return (trees, leaves)
    }

    @Test func freshBudgetEmitsNothingOnFirstSelection() {
        var evicted: [PaneSlotID] = []
        let budget = WorktreeSurfaceBudget(capacity: 4) { evicted.append($0) }
        let (trees, _) = singleLeafTrees(["/a"])
        budget.noteSelected(worktreePath: "/a", splitTreesByPath: trees)
        #expect(evicted.isEmpty)
    }

    @Test func fourDistinctSelectionsEvictNothing() {
        var evicted: [PaneSlotID] = []
        let budget = WorktreeSurfaceBudget(capacity: 4) { evicted.append($0) }
        let (trees, _) = singleLeafTrees(["/a", "/b", "/c", "/d"])
        for path in ["/a", "/b", "/c", "/d"] {
            budget.noteSelected(worktreePath: path, splitTreesByPath: trees)
        }
        #expect(evicted.isEmpty)
    }

    @Test func backgroundCreationEntersAtTailWithoutReorderingSelections() {
        var evicted: [PaneSlotID] = []
        let budget = WorktreeSurfaceBudget(capacity: 4) { evicted.append($0) }
        let (trees, _) = singleLeafTrees(["/a", "/b", "/c", "/d"])
        for path in ["/a", "/b", "/c"] {
            budget.noteSelected(worktreePath: path, splitTreesByPath: trees)
        }

        budget.noteCreated(worktreePath: "/d", splitTreesByPath: trees)

        #expect(budget.lru == ["/c", "/b", "/a", "/d"])
        #expect(evicted.isEmpty)
    }

    @Test func backgroundCreationAtCapacityEvictsItsOwnNeverSelectedSurface() {
        var evicted: [PaneSlotID] = []
        let budget = WorktreeSurfaceBudget(capacity: 4) { evicted.append($0) }
        let (trees, leaves) = singleLeafTrees(["/a", "/b", "/c", "/d", "/e"])
        for path in ["/a", "/b", "/c", "/d"] {
            budget.noteSelected(worktreePath: path, splitTreesByPath: trees)
        }

        budget.noteCreated(worktreePath: "/e", splitTreesByPath: trees)

        #expect(budget.lru == ["/d", "/c", "/b", "/a"])
        #expect(evicted == [leaves["/e"]])
    }

    @Test func fifthDistinctSelectionEvictsOldest() {
        var evicted: [PaneSlotID] = []
        let budget = WorktreeSurfaceBudget(capacity: 4) { evicted.append($0) }
        let (trees, leaves) = singleLeafTrees(["/a", "/b", "/c", "/d", "/e"])
        for path in ["/a", "/b", "/c", "/d", "/e"] {
            budget.noteSelected(worktreePath: path, splitTreesByPath: trees)
        }
        #expect(evicted == [leaves["/a"]])
    }

    @Test func reselectingHeadDoesNotEvict() {
        var evicted: [PaneSlotID] = []
        let budget = WorktreeSurfaceBudget(capacity: 4) { evicted.append($0) }
        let (trees, _) = singleLeafTrees(["/a", "/b", "/c", "/d"])
        for path in ["/a", "/b", "/c", "/d", "/a"] {
            budget.noteSelected(worktreePath: path, splitTreesByPath: trees)
        }
        #expect(evicted.isEmpty)
    }

    @Test func reselectingMovesPathToHead_thenFifthEvictsTrueOldest() {
        // Sequence A B C D A E: after A reselect, order is A D C B (head→tail).
        // Selecting E pushes B (the tail) out.
        var evicted: [PaneSlotID] = []
        let budget = WorktreeSurfaceBudget(capacity: 4) { evicted.append($0) }
        let (trees, leaves) = singleLeafTrees(["/a", "/b", "/c", "/d", "/e"])
        for path in ["/a", "/b", "/c", "/d", "/a", "/e"] {
            budget.noteSelected(worktreePath: path, splitTreesByPath: trees)
        }
        #expect(evicted == [leaves["/b"]])
    }

    @Test func selfPruneDropsHeadWhenMissingFromSnapshot() {
        var evicted: [PaneSlotID] = []
        let budget = WorktreeSurfaceBudget(capacity: 4) { evicted.append($0) }
        let (allTrees, _) = singleLeafTrees(["/a", "/b", "/c", "/d", "/e"])
        // Fill to 4 with all paths present
        for path in ["/a", "/b", "/c", "/d"] {
            budget.noteSelected(worktreePath: path, splitTreesByPath: allTrees)
        }
        // Now /a is no longer running — emulate via a snapshot missing /a.
        var without_a = allTrees
        without_a.removeValue(forKey: "/a")
        budget.noteSelected(worktreePath: "/e", splitTreesByPath: without_a)
        // /a was pruned (not evicted) so no callback fired for it; /b /c /d /e fit in 4.
        #expect(evicted.isEmpty)
    }

    @Test func selfPruneDropsTailWhenMissingFromSnapshot() {
        var evicted: [PaneSlotID] = []
        let budget = WorktreeSurfaceBudget(capacity: 4) { evicted.append($0) }
        let (allTrees, _) = singleLeafTrees(["/a", "/b", "/c", "/d", "/e"])
        for path in ["/a", "/b", "/c", "/d"] {
            budget.noteSelected(worktreePath: path, splitTreesByPath: allTrees)
        }
        var without_d = allTrees
        without_d.removeValue(forKey: "/d")
        budget.noteSelected(worktreePath: "/e", splitTreesByPath: without_d)
        #expect(evicted.isEmpty)
    }

    @Test func selfPruneCascadesAllStaleEntries() {
        var evicted: [PaneSlotID] = []
        let budget = WorktreeSurfaceBudget(capacity: 4) { evicted.append($0) }
        let (allTrees, _) = singleLeafTrees(["/a", "/b", "/c", "/d", "/e"])
        for path in ["/a", "/b", "/c", "/d"] {
            budget.noteSelected(worktreePath: path, splitTreesByPath: allTrees)
        }
        let onlyE: [String: SplitTree] = ["/e": allTrees["/e"]!]
        budget.noteSelected(worktreePath: "/e", splitTreesByPath: onlyE)
        #expect(evicted.isEmpty)
    }

    @Test func multiLeafWorktreeEvictsEveryLeaf() {
        let leaf1 = PaneSlotID()
        let leaf2 = PaneSlotID()
        let leaf3 = PaneSlotID()
        let aTree = SplitTree(root: .split(
            SplitTree.Node.Split(
                direction: .horizontal,
                ratio: 0.5,
                left: .leaf(leaf1),
                right: .split(
                    SplitTree.Node.Split(
                        direction: .vertical,
                        ratio: 0.5,
                        left: .leaf(leaf2),
                        right: .leaf(leaf3)
                    )
                )
            )
        ))
        let (otherTrees, _) = singleLeafTrees(["/b", "/c", "/d", "/e"])
        var trees = otherTrees
        trees["/a"] = aTree

        var evicted: [PaneSlotID] = []
        let budget = WorktreeSurfaceBudget(capacity: 4) { evicted.append($0) }
        for path in ["/a", "/b", "/c", "/d", "/e"] {
            budget.noteSelected(worktreePath: path, splitTreesByPath: trees)
        }
        #expect(Set(evicted) == Set([leaf1, leaf2, leaf3]))
    }
}
