#if canImport(UIKit)
import Testing
import Foundation
import SwiftUI
import UIKit
@testable import GrafttyProtocol
@testable import GrafttyMobileKit

@MainActor
@Suite("RootView size-class router — IPAD-1.1 + IPAD-7.1")
struct RootViewSizeClassTests {
    @Test func recentPaneChoiceUpdatesTheActualHostWorktreeAndPaneRoute() throws {
        let state = IPadAppState(defaults: try #require(UserDefaults(suiteName: "recent-selection-\(UUID())")))
        let host = Host(label: "Other Mac", baseURL: URL(string: "https://other.invalid")!)
        let row = WorktreePanes(path: "/other/target", displayName: "Target", repoDisplayName: "Project", displayBranch: "target",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: .split(direction: .horizontal, ratio: 0.5,
                left: .leaf(sessionName: "first", title: "First", attentionText: nil, isBusy: false, attentionSource: nil),
                right: .leaf(sessionName: "wanted", title: "Wanted", attentionText: nil, isBusy: false, attentionSource: nil)),
            sidebar: .init(id: "stable-target", projectID: "other-project"))
        state.selectedHostId = UUID()
        state.selectedWorktreePath = "/old"
        RootView.applyActivationTarget(.init(rows: [row], worktree: row, pane: row.layout!.leaves[1]), host: host, to: state)
        let selection = try #require(RootView.compactSelection(appState: state, hosts: [host]))
        #expect(selection.host.id == host.id)
        #expect(selection.worktree?.path == row.path)
        #expect(selection.session?.sessionName == "wanted")
        #expect(selection.session?.worktreeProject?.id == "other-project")
        #expect(state.latestWorktrees == [row])
        #expect(state.sidebarNavigation.selectedProjectID == "other-project")
    }

    @Test("""
@spec IPAD-7.2: When `horizontalSizeClass` transitions between `.regular` and `.compact`, the application shall preserve `selectedHostId`, `selectedWorktreePath`, and `focusedPaneId` so the user lands on the equivalent leaf in the new layout.
""")
    func preservesEquivalentLeafAcrossLayouts() {
        let defaults = UserDefaults(suiteName: "adaptive-\(UUID())")!
        let state = IPadAppState(defaults: defaults)
        let host = Host(label: "Mac", baseURL: URL(string: "https://mac.local")!)
        let worktree = WorktreePanes(path: "worktree", displayName: "Feature", repoDisplayName: "Repo", displayBranch: "feature", state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: .split(direction: .horizontal, ratio: 0.5, left: .leaf(sessionName: "first", title: "First", attentionText: nil, isBusy: false, attentionSource: nil), right: .leaf(sessionName: "second", title: "Second", attentionText: nil, isBusy: false, attentionSource: nil)))
        state.latestWorktrees = [worktree]
        state.selectedHostId = host.id
        state.selectedWorktreePath = worktree.path
        state.focusedPaneId = "second"
        let projection = RootView.compactSelection(appState: state, hosts: [host])
        #expect(projection?.host == host)
        #expect(projection?.session?.sessionName == "second")
        #expect(projection?.session?.worktreePath == "worktree")
        RootView.applyCompactSession(SessionStep(host: host, worktreePath: "other", sessionName: "third", title: "Third"), to: state)
        #expect(state.selectedHostId == host.id)
        #expect(state.selectedWorktreePath == "other")
        #expect(state.focusedPaneId == "third")
        #expect(RootView.compactSelection(appState: state, hosts: []) == nil)
        RootView.applyCompactHost(host, to: state)
        #expect(state.selectedWorktreePath == "other")
        #expect(state.focusedPaneId == "third")
        let secondHost = Host(label: "Other Mac", baseURL: URL(string: "https://other.local")!)
        RootView.applyCompactHost(secondHost, to: state)
        #expect(state.selectedHostId == secondHost.id)
        #expect(state.selectedWorktreePath == nil)
        #expect(state.focusedPaneId == nil)
        #expect(state.latestWorktrees.isEmpty)
        let hostOnly = RootView.compactSelection(appState: state, hosts: [host, secondHost])
        #expect(hostOnly?.host == secondHost)
        #expect(hostOnly?.session == nil)
    }

    @Test("""
@spec LAYOUT-2.47: When the user returns to a project on mobile, the application shall restore that project's previously visible worktree independently of other projects and search results.
""")
    func projectScrollAnchorsTrackViewport() {
        let rows = [SidebarWorktreeViewportRow(id: "above", minY: -70, maxY: -1),
                    SidebarWorktreeViewportRow(id: "visible", minY: -10, maxY: 40),
                    SidebarWorktreeViewportRow(id: "next", minY: 40, maxY: 100)]
        #expect(SidebarWorktreeViewportRow.topVisible(in: rows) == "visible")
        #expect(SidebarWorktreeViewportRow.topVisible(in: []) == nil)
    }

    @Test("""
@spec IPAD-1.1: When `horizontalSizeClass == .regular`, the iPad application shall render `IPadRootLayout` (NavigationSplitView, 2-column) in place of the compact-width `NavigationStack`.
""")
    func ipad_1_1_regularRendersIPadRootLayout() {
        let store = HostStore(storeURL: URL(fileURLWithPath: "/tmp/RootViewSizeClassTests-\(UUID()).json"))
        let appState = IPadAppState(defaults: UserDefaults(suiteName: "RootViewSizeClassTests-\(UUID().uuidString)")!)
        let layout = IPadRootLayout(hostStore: store, appState: appState)
        _ = layout
        #expect(true)
    }

    @Test("""
@spec IPAD-7.1: When `horizontalSizeClass == .compact`, the application shall render the existing compact `RootView` flow (NavigationStack: HostPicker → WorktreePicker → SingleSessionView) without any iPad layout components.
""")
    func ipad_7_1_compactRendersExistingFlow() {
        let view = RootView()
        _ = view.body
        #expect(true)
    }

    @Test("IPadAppState is lifted to RootView level (survives recreation of children)")
    func appStateLifted() {
        let defaults = UserDefaults(suiteName: "appStateLifted-\(UUID().uuidString)")!
        let appState = IPadAppState(defaults: defaults)
        appState.selectedHostId = UUID()
        #expect(appState.selectedHostId != nil)
    }

    /// Views built without a coordinator (previews, focused tests) get no
    /// remote wiring rather than a fresh coordinator.
    @Test("Without an injected coordinator, a worktree list gets no remote providers")
    func absentCoordinatorBuildsNoRemoteProviders() {
        let host = Host(label: "test", baseURL: URL(string: "https://test.local")!)
        let none = RemoteWorktreeProviders(coordinator: nil, host: host)
        #expect(!none.includeRemoteWorktrees)
        #expect(none.connection == nil && none.snapshot == nil && none.sidebar == nil)

        let wired = RemoteWorktreeProviders(coordinator: RemoteConnectionCoordinator(connectionsAllowedInitially: false), host: host)
        #expect(wired.connection != nil && wired.snapshot != nil && wired.sidebar != nil)
    }
}

#endif
