#if canImport(UIKit)
import Testing
import Foundation
import SwiftUI
@testable import GrafttyProtocol
@testable import GrafttyMobileKit

/// The compact `SingleSessionView` never consumes the app-state focus
/// requests, so a request made by a compact tap would stay pending and
/// summon the keyboard after a later regular-width transition.
@MainActor
@Suite("@spec IPAD-8.10: When a worktree or pane is selected at compact width, from the compact picker or a worktree context link, the application shall not add a terminal focus request to the shared app state, because only the regular-width detail column consumes those requests.")
struct CompactSelectionFocusTests {
    private func fixture() throws -> (IPadAppState, Host, WorktreePanes) {
        let state = IPadAppState(defaults: try #require(UserDefaults(suiteName: "compact-focus-\(UUID())")))
        let host = Host(label: "Mac", baseURL: URL(string: "https://fixture.invalid")!)
        let row = WorktreePanes(path: "/split", displayName: "Split", repoDisplayName: "Project", displayBranch: "split",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: .split(direction: .horizontal, ratio: 0.5,
                left: .leaf(sessionName: "first", title: "First", attentionText: nil, isBusy: false, attentionSource: nil),
                right: .leaf(sessionName: "second", title: "Second", attentionText: nil, isBusy: false, attentionSource: nil)))
        state.selectedHostId = host.id
        state.latestWorktrees = [row]
        return (state, host, row)
    }

    @Test func compactWorktreeTapDoesNotRequestFocus() throws {
        let (state, host, row) = try fixture()
        var path = NavigationPath()
        RootView.applyCompactWorktreeSelection(row, host: host, project: nil, appState: state, navigationPath: &path)
        #expect(state.focusedPaneId == "first")
        #expect(path.count == 1)
        #expect(state.focusRequestCount == 0)
    }

    @Test func compactPaneTapDoesNotRequestFocus() throws {
        let (state, host, row) = try fixture()
        let leaf = try #require(row.layout?.leaves.last)
        var path = NavigationPath()
        RootView.applyCompactPaneSelection(leaf, in: row, host: host, project: nil, appState: state, navigationPath: &path)
        #expect(state.focusedPaneId == "second")
        #expect(path.count == 1)
        #expect(state.focusRequestCount == 0)
    }

    @Test func compactContextLinkDoesNotRequestFocus() throws {
        let (state, host, row) = try fixture()
        let path = try #require(RootView.applyContextWorktree(row, host: host, appState: state,
                                                              compact: true, showsProjectRail: true))
        #expect(path.count == 3)
        #expect(state.selectedWorktreePath == row.path)
        #expect(state.focusedPaneId == "first")
        #expect(state.focusRequestCount == 0)
    }

    @Test func regularContextLinkRequestsFocus() throws {
        let (state, host, row) = try fixture()
        #expect(RootView.applyContextWorktree(row, host: host, appState: state,
                                              compact: false, showsProjectRail: true) == nil)
        #expect(state.selectedWorktreePath == row.path)
        #expect(state.focusRequestCount == 1)
    }

    @Test func regularSidebarSelectionRequestsFocus() throws {
        let (state, _, row) = try fixture()
        IPadRootLayout.applyWorktreeSelection(appState: state, worktree: row)
        #expect(state.focusRequestCount == 1)
        IPadRootLayout.applyPaneSelection(appState: state, leaf: try #require(row.layout?.leaves.last))
        #expect(state.focusRequestCount == 2)
        #expect(state.focusedPaneId == "second")
    }
}
#endif
