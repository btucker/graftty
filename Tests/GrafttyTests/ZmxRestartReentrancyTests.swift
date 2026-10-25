import SwiftUI
import Testing
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@Suite("@spec ZMX-8.2: When repositories or worktrees change during Restart ZMX confirmation, the application shall stop only still-running worktrees with the original repository and worktree identities, using their current panes and skipping removed entries.")
@MainActor
struct ZmxRestartReentrancyTests {
    @MainActor
    private final class StateBox {
        var state: AppState
        init(_ repos: [RepoEntry]) { state = AppState(repos: repos) }
        var binding: Binding<AppState> { Binding(get: { self.state }, set: { self.state = $0 }) }
    }

    private func running(_ path: String) -> WorktreeEntry {
        var worktree = WorktreeEntry(path: path, branch: "main", state: .running)
        let pane = PaneSlotID()
        worktree.splitTree = SplitTree(root: .leaf(pane))
        worktree.paneSessions = [pane: PaneSessionID()]
        return worktree
    }

    @Test(arguments: ["repo-reorder", "worktree-reorder", "repo-replace", "worktree-replace", "stopped"])
    func confirmationChangesMustNotRetargetStop(_ mutation: String) {
        let target = running("/target")
        let sibling = WorktreeEntry(path: "/sibling", branch: "sibling")
        let targetRepo = RepoEntry(path: "/target", displayName: "target", worktrees: [target, sibling])
        let other = RepoEntry(path: "/other", displayName: "other", worktrees: [sibling])
        let box = StateBox([targetRepo, other])
        var destroyed: [PaneSlotID] = []
        GrafttyApp.restartZMX(appState: box.binding, confirm: { panes, worktrees in
            #expect(panes == 1 && worktrees == 1)
            // This is the reentrancy boundary occupied by NSAlert.runModal.
            switch mutation {
            case "repo-reorder": box.state.repos.swapAt(0, 1)
            case "worktree-reorder": box.state.repos[0].worktrees.swapAt(0, 1)
            case "repo-replace":
                box.state.repos[0] = RepoEntry(path: targetRepo.path, displayName: "replacement", worktrees: [target])
            case "worktree-replace": box.state.repos[0].worktrees[0] = running(target.path)
            default: box.state.repos[0].worktrees[0].prepareForStop()
            }
            return true
        }, destroySurfaces: { destroyed += $0 })
        let shouldStop = mutation == "repo-reorder" || mutation == "worktree-reorder"
        #expect(destroyed == (shouldStop ? target.splitTree.allLeaves : []))
        #expect(box.state.repos.first(where: { $0.id == other.id }) == other)
        if shouldStop {
            let actual = box.state.repos.first(where: { $0.id == targetRepo.id })?.worktrees.first(where: { $0.id == target.id })
            #expect(actual?.state == .closed)
            #expect(actual?.splitTree == target.splitTree)
            #expect(actual?.paneSessions.isEmpty == true)
        } else if mutation != "stopped" {
            #expect(box.state.repos[0].worktrees[0].state == .running)
        }
    }

    @Test func stopsCurrentPanesAfterConfirmation() {
        let target = running("/target")
        let box = StateBox([RepoEntry(path: "/target", displayName: "target", worktrees: [target])])
        let newPane = PaneSlotID()
        var destroyed: [PaneSlotID] = []
        GrafttyApp.restartZMX(appState: box.binding, confirm: { _, _ in
            box.state.repos[0].worktrees[0].splitTree = SplitTree(root: .leaf(newPane))
            return true
        }, destroySurfaces: { destroyed += $0 })
        #expect(destroyed == [newPane])
        #expect(box.state.repos[0].worktrees[0].state == .closed)
    }

    @Test func removingTheLastRepositoryDuringConfirmationIsSafe() {
        let box = StateBox([RepoEntry(path: "/target", displayName: "target", worktrees: [running("/target")])])
        GrafttyApp.restartZMX(appState: box.binding, confirm: { _, _ in
            box.state.repos.removeAll()
            return true
        }, destroySurfaces: { _ in Issue.record("removed worktree must not be stopped") })
        #expect(box.state.repos.isEmpty)
    }

    @Test func teardownCallbacksCanRemoveRepositories() {
        let first = running("/first")
        let second = running("/second")
        let box = StateBox([
            RepoEntry(path: "/first", displayName: "first", worktrees: [first]),
            RepoEntry(path: "/second", displayName: "second", worktrees: [second]),
        ])
        var destroyed: [PaneSlotID] = []
        GrafttyApp.restartZMX(appState: box.binding, confirm: { _, _ in true }, destroySurfaces: { ids in
            destroyed += ids
            if ids == first.splitTree.allLeaves { box.state.repos.removeFirst() }
        })
        #expect(destroyed == first.splitTree.allLeaves + second.splitTree.allLeaves)
        #expect(box.state.repos.count == 1)
        #expect(box.state.repos[0].worktrees[0].id == second.id)
        #expect(box.state.repos[0].worktrees[0].state == .closed)
    }

    @Test func cancelDoesNotStopPanesOrChangeState() {
        let target = running("/target")
        let box = StateBox([RepoEntry(path: "/target", displayName: "target", worktrees: [target])])
        let before = box.state
        GrafttyApp.restartZMX(appState: box.binding, confirm: { _, _ in false }, destroySurfaces: { _ in
            Issue.record("cancel must not destroy surfaces")
        })
        #expect(box.state == before)
    }
}
