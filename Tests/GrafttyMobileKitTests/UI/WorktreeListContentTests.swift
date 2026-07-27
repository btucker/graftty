#if canImport(UIKit)
import Testing
import Foundation
import GrafttyProtocol
@testable import GrafttyMobileKit

@MainActor
@Suite("WorktreeListContent — extracted picker preserves callbacks + onListChanged")
struct WorktreeListContentTests {

    private func sampleHost() -> Host {
        Host(
            id: UUID(),
            label: "test",
            baseURL: URL(string: "https://test.local")!,
            addedAt: Date(),
            lastUsedAt: nil
        )
    }

    @Test("init stores host and three callbacks; onListChanged defaults to no-op")
    func initStoresCallbacks() {
        let h = sampleHost()
        let view = WorktreeListContent(
            host: h,
            onSelect: { _ in },
            onSelectPane: { _ in }
        )
        #expect(view.host.id == h.id)
        #expect(view.externalRefreshToken == 0)
        // No-op default doesn't crash when invoked.
        view.onListChanged([])
    }

    @Test("custom onListChanged is invoked with the supplied list")
    func customOnListChanged() {
        var received: [WorktreePanes]?
        let view = WorktreeListContent(
            host: sampleHost(),
            onSelect: { _ in },
            onSelectPane: { _ in },
            onListChanged: { list in received = list },
            externalRefreshToken: 3
        )
        view.onListChanged([])
        #expect(received != nil && received?.isEmpty == true)
        #expect(view.externalRefreshToken == 3)
    }

    @Test("WorktreePickerView wrapper delegates to WorktreeListContent")
    func wrapperDelegates() {
        let h = sampleHost()
        let wrapper = WorktreePickerView(
            host: h,
            onSelect: { _ in },
            onSelectPane: { _ in }
        )
        #expect(wrapper.host.id == h.id)
    }

    @Test("""
@spec IPAD-1.19: While rendering iPad sidebar worktree rows, the application shall use a tight trailing inset so git divergence stats sit near the sidebar edge.
""")
    func tightTrailingInset() {
        #expect(WorktreeListContent.iPadRowTrailingInset <= 4)
    }

    @Test("""
    @spec REMOTE-13.18: When GrafttyMobile selects a closed local or relayed \
    worktree over an authenticated management connection, the application \
    shall open the worktree before navigating to its running pane layout.
    """)
    func closedWorktreesRequireManagementOpen() {
        func worktree(state: WorktreeWireState) -> WorktreePanes {
            WorktreePanes(
                path: "worktree",
                displayName: "worktree",
                repoDisplayName: "repo",
                displayBranch: "feature",
                state: state,
                isMainCheckout: false,
                prBadge: nil,
                stats: nil,
                attentionText: nil,
                layout: nil
            )
        }

        #expect(WorktreeListContent.requiresManagementOpen(
            worktree(state: .closed),
            includesRemoteWorktrees: true,
            providerAvailable: true
        ))
        #expect(!WorktreeListContent.requiresManagementOpen(
            worktree(state: .running),
            includesRemoteWorktrees: true,
            providerAvailable: true
        ))
        #expect(!WorktreeListContent.requiresManagementOpen(
            worktree(state: .closed),
            includesRemoteWorktrees: true,
            providerAvailable: false
        ))
        #expect(!WorktreeListContent.requiresManagementOpen(
            worktree(state: .closed),
            includesRemoteWorktrees: false,
            providerAvailable: true
        ))
        #expect(WorktreeListContent.shouldApplySelectionIntent(
            capturedGeneration: 4,
            currentGeneration: 4
        ))
        #expect(!WorktreeListContent.shouldApplySelectionIntent(
            capturedGeneration: 4,
            currentGeneration: 5
        ))
    }

    @Test("force-delete confirmation cannot cross host boundaries")
    func forceDeleteConfirmationIsHostScoped() {
        let originalHostID = UUID()

        #expect(WorktreeListContent.forceDeleteMatchesHost(
            capturedHostID: originalHostID,
            currentHostID: originalHostID
        ))
        #expect(!WorktreeListContent.forceDeleteMatchesHost(
            capturedHostID: originalHostID,
            currentHostID: UUID()
        ))
    }
}
#endif
