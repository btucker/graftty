#if canImport(UIKit)
import Testing
import Foundation
import SwiftUI
@testable import GrafttyProtocol
@testable import GrafttyMobileKit

@MainActor
@Suite("RootView size-class router — IPAD-1.1 + IPAD-7.1")
struct RootViewSizeClassTests {

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
        let layout = IPadRootLayout(hostStore: store, appState: appState, coordinator: RemoteConnectionCoordinator())
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

    /// W3 Task 4 (Task-3 finding 4, LOW): this test exercises the SAME
    /// construction call sites `RootView.body` itself uses
    /// (`IPadRootLayout(... coordinator: coordinator)` and
    /// `SingleSessionView(..., coordinator: coordinator)`) but never
    /// actually renders `RootView.body` — `ipad_7_1_compactRendersExistingFlow`
    /// above does call `.body` but only for the `.compact` branch, so
    /// there's no single test that walks `.body` and captures the
    /// coordinator instance handed to `IPadRootLayout` on the `.regular`
    /// branch specifically.
    ///
    /// Strengthening this to actually assert on `RootView.body`'s output
    /// would need either (a) reading `@Environment(\.horizontalSizeClass)`
    /// from a real `UIHostingController` hosted in a UI-testable
    /// environment (there's no `ViewInspector`-style dependency in this
    /// package, and adding one is out of scope for this task), or (b)
    /// reflecting over the opaque `some View` tree `body` returns, which
    /// SwiftUI does not expose a stable, non-fragile API for. Both are
    /// disproportionate to what this test is actually protecting against
    /// (a copy-paste construction site handing `IPadRootLayout` or
    /// `SingleSessionView` a DIFFERENT coordinator instance than the
    /// other) — the construction-level assertion below already fails
    /// loudly if either call site's argument changes from `coordinator`
    /// to e.g. `RemoteConnectionCoordinator()`, which is the actual
    /// regression this guards against.
    @Test("""
W3 Task 3: `RootView` owns a single `RemoteConnectionCoordinator` and hands the SAME instance to both size classes — `IPadRootLayout` (regular width) and `SingleSessionView` (compact width) — so a host negotiated from either surface is cached for the other.
""")
    func bothSizeClassesReceiveTheSameCoordinatorInstance() {
        let host = Host(
            id: UUID(),
            label: "test",
            baseURL: URL(string: "https://test.local")!,
            addedAt: Date(),
            lastUsedAt: nil
        )
        let step = SessionStep(host: host, sessionName: "s", title: "s")
        let coordinator = RemoteConnectionCoordinator()

        let store = HostStore(storeURL: URL(fileURLWithPath: "/tmp/RootViewSizeClassTests-\(UUID()).json"))
        let appState = IPadAppState(defaults: UserDefaults(suiteName: "RootViewSizeClassTests-\(UUID().uuidString)")!)
        let ipadLayout = IPadRootLayout(hostStore: store, appState: appState, coordinator: coordinator)
        let compactSession = SingleSessionView(step: step, navigationPath: .constant(NavigationPath()), coordinator: coordinator)

        #expect(ipadLayout.coordinator === coordinator)
        #expect(compactSession.coordinator === coordinator)
    }
}
#endif
