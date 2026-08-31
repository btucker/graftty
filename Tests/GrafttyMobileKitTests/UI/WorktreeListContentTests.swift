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

    @Test("""
    @spec IOS-4.30: When a paired host's worktree list mounts before the biometric gate has made authenticated connections available, the application shall keep the initial loading state pending and automatically start the load when the active, unlocked readiness state arrives. A successful list shall remain mounted across transient inactive/active cycles, while changing hosts shall automatically load the new host without requiring Refresh.
    """)
    func initialLoadTracksConnectionReadinessAndHostIdentity() {
        let firstHostID = UUID()

        #expect(!WorktreeListContent.shouldAutomaticallyLoad(
            hostID: firstHostID,
            loadedHostID: nil,
            isReady: false
        ))
        #expect(WorktreeListContent.shouldAutomaticallyLoad(
            hostID: firstHostID,
            loadedHostID: nil,
            isReady: true
        ))
        #expect(!WorktreeListContent.shouldAutomaticallyLoad(
            hostID: firstHostID,
            loadedHostID: firstHostID,
            isReady: true
        ))
        #expect(WorktreeListContent.shouldAutomaticallyLoad(
            hostID: UUID(),
            loadedHostID: firstHostID,
            isReady: true
        ))

        let secondHostID = UUID()
        #expect(!WorktreeListContent.shouldApplyLoadResult(
            requestHostID: firstHostID,
            presentedHostID: secondHostID,
            isCancelled: false
        ))
        #expect(!WorktreeListContent.shouldApplyLoadResult(
            requestHostID: secondHostID,
            presentedHostID: secondHostID,
            isCancelled: true
        ))
        #expect(WorktreeListContent.shouldApplyLoadResult(
            requestHostID: secondHostID,
            presentedHostID: secondHostID,
            isCancelled: false
        ))
    }

    @Test("""
    @spec IOS-4.31: When authenticated worktree polling receives a snapshot equal to the list already rendered, the application shall not republish `onListChanged` or replace the list state. It shall publish a genuinely changed snapshot so pane metadata and topology still update promptly.
    """)
    func identicalPollingSnapshotsDoNotRepublishThePaneHierarchy() {
        let current = [sampleWorktree(path: "/repo/first")]

        #expect(!WorktreeListContent.shouldPublishLoadedList(
            current: .loaded(current),
            next: current
        ))
        #expect(WorktreeListContent.shouldPublishLoadedList(
            current: .loaded(current),
            next: [sampleWorktree(path: "/repo/second")]
        ))
        #expect(WorktreeListContent.shouldPublishLoadedList(
            current: .loading,
            next: current
        ))
    }

    @Test("WorktreePickerView wrapper delegates to WorktreeListContent")
    func wrapperDelegates() {
        let h = sampleHost()
        let coordinator = RemoteConnectionCoordinator()
        let wrapper = WorktreePickerView(
            host: h,
            coordinator: coordinator,
            onSelect: { _ in },
            onSelectPane: { _ in }
        )
        let requiredCoordinator: RemoteConnectionCoordinator =
            wrapper.coordinator
        #expect(wrapper.host.id == h.id)
        #expect(requiredCoordinator === coordinator)
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

    @Test("downstream Mac rows expose state-specific reconnect actions")
    func remoteMacConnectionRowActions() {
        #expect(RemoteMacConnectionSummary.State.offline.mobileCanReconnect)
        #expect(RemoteMacConnectionSummary.State.failed.mobileCanReconnect)
        #expect(RemoteMacConnectionSummary.State.discovered.mobileCanReconnect)
        #expect(!RemoteMacConnectionSummary.State.connecting.mobileCanReconnect)
        #expect(RemoteMacConnectionSummary.State.connected.mobileCanReconnect)
        #expect(!RemoteMacConnectionSummary.State.needsPairing.mobileCanReconnect)
        #expect(
            RemoteMacConnectionSummary.State.discovered.mobileReconnectLabel
                == "Connect"
        )
        #expect(
            RemoteMacConnectionSummary.State.offline.mobileReconnectLabel
                == "Reconnect"
        )
    }

    @Test("""
    @spec IOS-4.29: While the initial authenticated worktree load remains \
    incomplete for at least 750 milliseconds, the application shall reveal \
    the current connection stage and elapsed time. Loads that finish sooner \
    shall keep the loading presentation compact.
    """)
    func delayedLoadingDetailsDescribeRealStages() {
        #expect(
            WorktreeLoadingView.detail(
                for: .connecting,
                hostLabel: "Studio"
            ) == "Connecting securely to Studio…"
        )
        #expect(
            WorktreeLoadingView.detail(
                for: .openingChannel,
                hostLabel: "Studio"
            ) == "Opening secure worktree channel…"
        )
        #expect(
            WorktreeLoadingView.detail(
                for: .waitingForSnapshot,
                hostLabel: "Studio"
            ) == "Waiting for worktree list…"
        )
        #expect(
            WorktreeLoadingView.detailRevealDelay == .milliseconds(750)
        )

        let startedAt = Date(timeIntervalSince1970: 100)
        #expect(WorktreeLoadingView.elapsedText(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(3.9)
        ) == "Elapsed 3s")
        #expect(WorktreeLoadingView.elapsedText(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(-1)
        ) == "Elapsed 0s")
    }

    private func sampleWorktree(path: String) -> WorktreePanes {
        WorktreePanes(
            path: path,
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            repoDisplayName: "repo",
            displayBranch: "main",
            state: .running,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: nil
        )
    }
}
#endif
