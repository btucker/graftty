import AppKit
import SwiftUI
import Testing
import GrafttyKit
@testable import Graftty

@Suite("Breadcrumb history presentation")
struct BreadcrumbHistoryPresentationTests {
    @MainActor
    @Test("@spec LAYOUT-1.11: When assistive technology focuses the breadcrumb button, the application shall expose the selected repository, worktree, and branch alongside the recent-worktrees action.")
    func accessibilityIncludesCurrentLocation() {
        let bar = BreadcrumbBar(repoName: "Graftty", worktreeDisplayName: "header-nav", worktreeEmoji: nil,
            worktreePath: "/repo/header-nav", branchName: "feature/header", isHomeCheckout: false,
            prInfo: nil, theme: .fallback, sidebarHidden: false,
            canGoBack: false, canGoForward: false, historyItems: [], currentTarget: .local("/repo/header-nav"),
            onGoBack: {}, onGoForward: {}, onSelectHistory: { _ in }, onRefreshPR: {})
        #expect(bar.currentLocationAccessibilityValue == "Graftty, header-nav, Branch feature/header")
        let empty = BreadcrumbBar(repoName: nil, worktreeDisplayName: nil, worktreeEmoji: nil,
            worktreePath: nil, branchName: nil, isHomeCheckout: false,
            prInfo: nil, theme: .fallback, sidebarHidden: false,
            canGoBack: false, canGoForward: false, historyItems: [], currentTarget: nil,
            onGoBack: {}, onGoForward: {}, onSelectHistory: { _ in }, onRefreshPR: {})
        #expect(empty.currentLocationAccessibilityValue.isEmpty)
    }

    @Test("Recent entries identify their repository, branch, and remote Mac")
    func menuTitles() {
        let local = BreadcrumbHistoryItem(target: .local("/repo/feature"), repoName: "repo",
            worktreeName: "feature", branchName: "feat/header", remoteMacName: nil)
        #expect(local.menuTitle == "repo / feature (feat/header)")
        #expect(local.path == "/repo/feature")
        let remote = BreadcrumbHistoryItem(target: local.target, repoName: local.repoName,
            worktreeName: local.worktreeName, branchName: local.branchName, remoteMacName: "Studio")
        #expect(remote.menuTitle == "repo / feature (feat/header) · Studio")
    }

    @MainActor
    @Test("Long breadcrumbs leave room for navigation in either sidebar state")
    func longBreadcrumbsStayBounded() {
        for sidebarHidden in [false, true] {
            let item = BreadcrumbHistoryItem(target: .local("/repo/feature"),
                repoName: String(repeating: "long-repository-", count: 8),
                worktreeName: String(repeating: "long-worktree-", count: 8),
                branchName: String(repeating: "long-branch-", count: 8), remoteMacName: nil)
            let bar = BreadcrumbBar(repoName: item.repoName, worktreeDisplayName: item.worktreeName, worktreeEmoji: nil,
                worktreePath: item.path, branchName: item.branchName, isHomeCheckout: false,
                prInfo: nil, theme: .fallback, sidebarHidden: sidebarHidden,
                canGoBack: true, canGoForward: false, historyItems: [item], currentTarget: item.target,
                onGoBack: {}, onGoForward: {}, onSelectHistory: { _ in }, onRefreshPR: {})
            let size = NSHostingController(rootView: bar).sizeThatFits(in: CGSize(width: 400, height: 1000))
            #expect(size.width <= 400.5)
            #expect(size.height <= 44)
        }
    }
}
