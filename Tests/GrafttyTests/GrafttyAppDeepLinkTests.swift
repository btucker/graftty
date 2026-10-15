import SwiftUI
import Testing
@testable import Graftty
import GrafttyKit

@MainActor
@Suite("GrafttyApp deep links")
struct GrafttyAppDeepLinkTests {
    @Test("@spec SLEEP-17: If a deep-linked worktree cannot be resumed, then the application shall preserve the current selection and defer surface attachment.")
    func failedWakePreservesSelection() throws {
        let worktree = WorktreeEntry(path: "/repo/feature", branch: "feature", state: .running)
        var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "repo", worktrees: [worktree])], selectedWorktreePath: "/repo/other")
        let binding = Binding(get: { state }, set: { state = $0 })
        let url = try #require(URL(string: "graftty://open?repo=repo&worktree=feature"))
        #expect(!GrafttyApp.applyDeepLink(url, appState: binding, admitWorktree: { _ in false },
            prepareRunningWorktree: { _ in Issue.record("Attached before wake succeeded") }))
        #expect(state.selectedWorktreePath == "/repo/other")
    }

    @Test("@spec URL-2.2: When a macOS deep link selects a running worktree, the application shall restore any missing terminal surfaces using the worktree's existing pane sessions before bringing the app to the foreground.")
    func runningTargetPreparesSurfacesAndPreservesSession() throws {
        let pane = PaneSlotID()
        let session = PaneSessionID()
        var worktree = WorktreeEntry(path: "/repo/feature", branch: "feature", state: .running)
        worktree.splitTree = SplitTree(root: .leaf(pane))
        worktree.paneSessions[pane] = session
        var state = AppState(
            repos: [RepoEntry(path: "/repo", displayName: "repo", worktrees: [worktree])],
            selectedWorktreePath: "/repo/other"
        )
        let binding = Binding(get: { state }, set: { state = $0 })
        var prepared: [WorktreeEntry] = []
        let url = try #require(URL(string: "graftty://open?session=\(ZmxLauncher.sessionName(for: session))"))

        #expect(GrafttyApp.applyDeepLink(
            url,
            appState: binding,
            prepareRunningWorktree: { prepared.append($0) }
        ))

        #expect(prepared.count == 1)
        #expect(prepared.first?.path == worktree.path)
        #expect(prepared.first?.splitTree.allLeaves == [pane])
        #expect(prepared.first?.paneSessions[pane] == session)
        #expect(state.selectedWorktreePath == worktree.path)
        #expect(state.worktree(forPath: worktree.path)?.focusedPaneSlotID == pane)
    }

    @Test("A deep link does not start a closed worktree")
    func closedTargetKeepsItsLifecycleState() throws {
        let worktree = WorktreeEntry(path: "/repo/feature", branch: "feature", state: .closed)
        var state = AppState(repos: [
            RepoEntry(path: "/repo", displayName: "repo", worktrees: [worktree])
        ])
        let binding = Binding(get: { state }, set: { state = $0 })
        let url = try #require(URL(string: "graftty://open?repo=repo&worktree=feature"))

        #expect(GrafttyApp.applyDeepLink(
            url,
            appState: binding,
            prepareRunningWorktree: { _ in Issue.record("Closed target unexpectedly prepared surfaces") }
        ))
        #expect(state.selectedWorktreePath == worktree.path)
        #expect(state.worktree(forPath: worktree.path)?.state == .closed)
    }

    @Test("An unresolved deep link leaves selection and surfaces alone")
    func unresolvedTargetDoesNotActivate() throws {
        var state = AppState(selectedWorktreePath: "/repo/other")
        let binding = Binding(get: { state }, set: { state = $0 })
        let url = try #require(URL(string: "graftty://open?session=unknown"))

        #expect(!GrafttyApp.applyDeepLink(
            url,
            appState: binding,
            prepareRunningWorktree: { _ in Issue.record("Unresolved target unexpectedly prepared surfaces") }
        ))
        #expect(state.selectedWorktreePath == "/repo/other")
    }
}
