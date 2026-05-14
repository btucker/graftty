import Foundation
import Testing
@testable import GrafttyKit

@Suite("AppState.runningSplitTreesByPath")
struct AppStateRunningSplitTreesTests {

    private func makeState(
        worktrees: [(path: String, branch: String, state: WorktreeState, leaves: [PaneSlotID])]
    ) -> AppState {
        let entries: [WorktreeEntry] = worktrees.map { spec in
            var wt = WorktreeEntry(path: spec.path, branch: spec.branch, state: spec.state)
            if let first = spec.leaves.first {
                var node: SplitTree.Node = .leaf(first)
                for leaf in spec.leaves.dropFirst() {
                    node = .split(
                        SplitTree.Node.Split(
                            direction: .horizontal,
                            ratio: 0.5,
                            left: node,
                            right: .leaf(leaf)
                        )
                    )
                }
                wt.splitTree = SplitTree(root: node)
            }
            return wt
        }
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: entries)
        return AppState(repos: [repo])
    }

    @Test func includesOnlyRunningWorktrees() {
        let runningLeaf = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)
        let closedLeaf = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!)
        let staleLeaf = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!)

        let state = makeState(worktrees: [
            ("/repo/running", "running", .running, [runningLeaf]),
            ("/repo/closed", "closed", .closed, [closedLeaf]),
            ("/repo/stale", "stale", .stale, [staleLeaf]),
        ])

        let map = state.runningSplitTreesByPath()
        #expect(map.keys.sorted() == ["/repo/running"])
        #expect(map["/repo/running"]?.containsLeaf(runningLeaf) == true)
    }

    @Test func emptyWhenNoRunningWorktrees() {
        let state = makeState(worktrees: [
            ("/repo/closed", "closed", .closed, [PaneSlotID()]),
        ])
        #expect(state.runningSplitTreesByPath().isEmpty)
    }

    @Test func multipleRunningWorktreesPreserveSplitTrees() {
        let a = PaneSlotID()
        let b1 = PaneSlotID()
        let b2 = PaneSlotID()

        let state = makeState(worktrees: [
            ("/repo/a", "a", .running, [a]),
            ("/repo/b", "b", .running, [b1, b2]),
        ])

        let map = state.runningSplitTreesByPath()
        #expect(map.count == 2)
        #expect(map["/repo/a"]?.allLeaves == [a])
        #expect(map["/repo/b"]?.allLeaves.sorted(by: { $0.id.uuidString < $1.id.uuidString })
                == [b1, b2].sorted(by: { $0.id.uuidString < $1.id.uuidString }))
    }
}
