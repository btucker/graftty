import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite("@spec IOS-4.14: When a worktree's pane layout is a single leaf, the worktree-detail screen shall render a static labeled tile rather than a live terminal preview, and shall not open a preview WebSocket for that pane.")
struct WorktreeDetailSinglePaneTests {
    @Test
    func leafIsRecognizedAsSinglePane() {
        #expect(PaneLayoutNode.leaf(sessionName: "only", title: "Only", attentionText: nil, isBusy: false, attentionSource: nil).isLeaf)
    }

    @Test
    func splitIsNotASinglePane() {
        let layout = PaneLayoutNode.split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(sessionName: "left", title: "Left", attentionText: nil, isBusy: false, attentionSource: nil),
            right: .leaf(sessionName: "right", title: "Right", attentionText: nil, isBusy: false, attentionSource: nil)
        )
        #expect(!layout.isLeaf)
    }
}

#if canImport(UIKit)
import Foundation

@MainActor
@Suite("""
W3 Task 3: `WorktreeDetailView` threads a `RemoteConnectionCoordinator` through so its preview pool can ride SSH-over-WebRTC when the host is paired, instead of always falling back to `/ws`.
""")
struct WorktreeDetailViewCoordinatorWiringTests {
    @Test
    func storesTheInjectedCoordinator() {
        let host = Host(
            id: UUID(),
            label: "test",
            baseURL: URL(string: "https://test.local")!,
            addedAt: Date(),
            lastUsedAt: nil
        )
        let worktree = WorktreePanes(
            path: "/repo/feat",
            displayName: "feat",
            repoDisplayName: "repo",
            displayBranch: "feature",
            state: .running,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: nil
        )
        let coordinator = RemoteConnectionCoordinator()
        let view = WorktreeDetailView(host: host, worktree: worktree, coordinator: coordinator) { _ in }
        #expect(view.coordinator === coordinator)
    }

    @Test
    func defaultsToNilCoordinatorForBackwardCompatibleConstruction() {
        let host = Host(
            id: UUID(),
            label: "test",
            baseURL: URL(string: "https://test.local")!,
            addedAt: Date(),
            lastUsedAt: nil
        )
        let worktree = WorktreePanes(
            path: "/repo/feat",
            displayName: "feat",
            repoDisplayName: "repo",
            displayBranch: "feature",
            state: .running,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: nil
        )
        let view = WorktreeDetailView(host: host, worktree: worktree) { _ in }
        #expect(view.coordinator == nil)
    }
}
#endif
