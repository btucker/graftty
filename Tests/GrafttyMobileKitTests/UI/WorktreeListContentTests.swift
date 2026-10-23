#if canImport(UIKit)
import Testing
import Foundation
import GrafttyProtocol
import GrafttyCommandUI
import SwiftUI
import UIKit
@testable import GrafttyMobileKit

@MainActor
@Suite("WorktreeListContent — extracted picker preserves callbacks + onListChanged")
struct WorktreeListContentTests {

    @Test("@spec IPAD-1.22: While the iPad split-view sidebar has a compact column size class, the application shall retain the project rail and select projects within the sidebar rather than push compact navigation destinations.", arguments: [true, false])
    func splitViewSidebarRetainsProjectSelection(collapsed: Bool) async throws {
        let suite = "ipad-project-selection-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SidebarLayoutPolicy.projectRailSettingKey)
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults, collapsed: collapsed)
        let rows = [sampleWorktree(path: "/repo/first")]
        let controller = UIHostingController(rootView: WorktreeListContent(
            host: sampleHost(), isSidebar: true,
            remote: RemoteWorktreeProviders(snapshot: { _, _ in rows }),
            onSelect: { _ in }, onSelectPane: { _, _ in }, navigation: navigation
        ).defaultAppStorage(defaults).environment(\.horizontalSizeClass, .compact))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 500, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var railScrollView: UIScrollView?
        func findRail(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView,
               scroll.bounds.width == (collapsed ? 64 : 196) { return scroll }
            return view.subviews.lazy.compactMap { findRail(in: $0) }.first
        }
        // Loading and SwiftUI mounting are asynchronous. Wait for the rail,
        // without relying on private SwiftUI view names or a fixed delay.
        for _ in 0..<50 {
            controller.view.layoutIfNeeded()
            railScrollView = findRail(in: controller.view)
            if railScrollView != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(railScrollView != nil)
        let project = SidebarProjection.projects(rows)[0]
        var generation: UInt64 = 0
        WorktreeListContent.applyProjectSelection(project, navigation: navigation, selectionGeneration: &generation)
        #expect(navigation.selectedProjectID == project.id)
        #expect(generation == 1)
    }

    @Test("@spec IOS-4.38: When a compact mobile project is selected, the application shall push its worktrees as a separate native navigation destination so the system Back button and edge swipe return to the project list.")
    func projectDestinationHasItsOwnSelection() {
        let project = SidebarProject(id: "repo", repositoryID: "repo", name: "Repo")
        let step = ProjectStep(host: sampleHost(), project: project)
        let root = WorktreePickerView(host: step.host,
            onSelect: { _ in }, onSelectPane: { _, _ in })
        let destination = WorktreePickerView(host: step.host,
            onSelect: { _ in }, onSelectPane: { _, _ in }, project: step.project)
        #expect(root.project == nil)
        #expect(destination.project?.id == "repo")
        let navigation = SidebarNavigationState(prefix: "project-route-\(UUID())")
        navigation.showProject("different-project")
        // Changing shared sidebar selection must not replace either stack level.
        #expect(root.project == nil)
        #expect(destination.project?.id == "repo")
    }

    @Test("Navigation metadata accepts matching legacy snapshots and rejects missing or mismatched generations")
    func metadataMustMatchDisplayedRows() {
        let rows = [WorktreePanes(path: "old", displayName: "Feature", repoDisplayName: "Repo", displayBranch: "feature", state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil)]
        #expect(WorktreeListContent.shouldApplyNavigationSnapshot(.snapshot(rows), matching: rows))
        #expect(!WorktreeListContent.shouldApplyNavigationSnapshot(nil, matching: rows))
        #expect(!WorktreeListContent.shouldApplyNavigationSnapshot(.snapshot([]), matching: rows))
    }

    @Test("Selecting a project cancels an outstanding report open, including offline projects")
    func projectChangesCancelReportOpen() {
        let defaults = UserDefaults(suiteName: "selection-\(UUID())")!
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        var generation: UInt64 = 7
        for isAvailable in [true, false] {
            let pending = generation
            let project = SidebarProject(id: "project", repositoryID: "repo", name: "Project", isAvailable: isAvailable)
            WorktreeListContent.applyProjectSelection(project, navigation: navigation, selectionGeneration: &generation)
            #expect(!WorktreeListContent.shouldApplySelectionIntent(capturedGeneration: pending, currentGeneration: generation))
            #expect(navigation.selectedProjectID == "project")
            #expect(!navigation.compactShowsProjects)
        }

    }

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
            onSelectPane: { _, _ in }
        )
        #expect(view.host.id == h.id)
        // No-op default doesn't crash when invoked.
        view.onListChanged([])
    }

    @Test("custom onListChanged is invoked with the supplied list")
    func customOnListChanged() {
        var received: [WorktreePanes]?
        let view = WorktreeListContent(
            host: sampleHost(),
            onSelect: { _ in },
            onSelectPane: { _, _ in },
            onListChanged: { list in received = list }
        )
        view.onListChanged([])
        #expect(received != nil && received?.isEmpty == true)
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
    @spec IOS-4.31: When an authenticated worktree push or refresh delivers rows equal to the list already rendered, the application shall not republish `onListChanged` or replace the list state. It shall publish a genuinely changed snapshot so pane metadata and topology still update promptly.
    """)
    func identicalSnapshotsDoNotRepublishThePaneHierarchy() {
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

    @Test("@spec IOS-4.52: While a paired host's worktree list is displayed, when the host pushes a changed panes-state frame, the application shall render it and publish it through onListChanged without fetching the list again.", .timeLimit(.minutes(1)))
    func pushedFrameUpdatesTheListWithoutAFetch() async throws {
        enum Event: Equatable { case fetched, published([WorktreePanes]) }
        let suite = "worktree-push-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = [sampleWorktree(path: "/repo/first")]
        let pushed = initial + [sampleWorktree(path: "/repo/second")]
        let events = AsyncStream<Event>.makeStream()
        let frames = AsyncStream<RemoteWorktreeUpdate>.makeStream()
        let controller = UIHostingController(rootView: WorktreeListContent(
            host: sampleHost(),
            remote: RemoteWorktreeProviders(
                includeRemoteWorktrees: true,
                snapshot: { _, _ in events.continuation.yield(.fetched); return initial },
                updates: { frames.stream }
            ),
            onSelect: { _ in }, onSelectPane: { _, _ in },
            onListChanged: { events.continuation.yield(.published($0)) },
            navigation: SidebarNavigationState(prefix: "test", defaults: defaults, collapsed: true)
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        var observed = events.stream.makeAsyncIterator()
        try #require(await observed.next() == .fetched)
        try #require(await observed.next() == .published(initial))
        frames.continuation.yield(.frame(.snapshot(pushed)))
        // A polling list fetches again instead of applying the pushed frame.
        #expect(await observed.next() == .published(pushed))
    }

    @Test("@spec IOS-4.54: If a pulled worktree list completes after a newer pushed panes-state frame was applied, then the application shall keep the pushed frame rather than replace it with the pulled rows.", .timeLimit(.minutes(1)))
    func lateInitialLoadDoesNotOverwriteNewerPushedFrames() async throws {
        enum Event: Equatable { case fetched, published([WorktreePanes]) }
        let suite = "worktree-late-load-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stale = [sampleWorktree(path: "/repo/a")]
        func frame(_ paths: String...) -> [WorktreePanes] { paths.map { sampleWorktree(path: "/repo/\($0)") } }
        let events = AsyncStream<Event>.makeStream()
        let frames = AsyncStream<RemoteWorktreeUpdate>.makeStream()
        let load = HeldLoad()
        let loadReturned = AsyncStream<Void>.makeStream()
        let controller = UIHostingController(rootView: WorktreeListContent(
            host: sampleHost(),
            remote: RemoteWorktreeProviders(
                includeRemoteWorktrees: true,
                snapshot: { _, _ in
                    events.continuation.yield(.fetched)
                    await load.wait()
                    loadReturned.continuation.yield()
                    return stale
                },
                updates: { frames.stream }
            ),
            onSelect: { _ in }, onSelectPane: { _, _ in },
            onListChanged: { events.continuation.yield(.published($0)) },
            navigation: SidebarNavigationState(prefix: "test", defaults: defaults, collapsed: true)
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; load.release() }

        var observed = events.stream.makeAsyncIterator()
        // The initial load is in flight; pushed frames still render.
        try #require(await observed.next() == .fetched)
        frames.continuation.yield(.frame(.snapshot(frame("b"))))
        try #require(await observed.next() == .published(frame("b")))
        frames.continuation.yield(.frame(.snapshot(frame("b", "c"))))
        try #require(await observed.next() == .published(frame("b", "c")))

        // The load now completes with rows older than the pushed frames. Its
        // rows are applied (or dropped) in the same main-actor job that
        // returns them, before this test resumes, so the next published list
        // shows which happened.
        load.release()
        var returned = loadReturned.stream.makeAsyncIterator()
        try #require(await returned.next() != nil)
        frames.continuation.yield(.frame(.snapshot(frame("b", "c", "d"))))
        #expect(await observed.next() == .published(frame("b", "c", "d")))
        frames.continuation.yield(.frame(.snapshot(frame("b", "c", "d", "e"))))
        #expect(await observed.next() == .published(frame("b", "c", "d", "e")))
    }

    @Test("@spec IOS-4.53: When the host whose worktree list is displayed becomes paired, the application shall begin applying the host's pushed panes-state frames without requiring Refresh.", .timeLimit(.minutes(1)))
    func pairingTheDisplayedHostStartsApplyingPushedFrames() async throws {
        struct NotPaired: Error {}
        let suite = "worktree-pairing-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults, collapsed: true)
        let host = sampleHost()
        let pushed = [sampleWorktree(path: "/repo/first")]
        let fetches = AsyncStream<Void>.makeStream()
        let frames = AsyncStream<RemoteWorktreeUpdate>.makeStream()
        var published: [[WorktreePanes]] = []
        // Pairing in place keeps the host's ID; only its providers change.
        func list(paired: Bool) -> WorktreeListContent {
            var updates: (@MainActor () -> AsyncStream<RemoteWorktreeUpdate>)?
            if paired { updates = { frames.stream } }
            return WorktreeListContent(
                host: host,
                remote: RemoteWorktreeProviders(
                    includeRemoteWorktrees: paired,
                    snapshot: { _, _ in fetches.continuation.yield(); throw NotPaired() },
                    updates: updates
                ),
                onSelect: { _ in }, onSelectPane: { _, _ in },
                onListChanged: { published.append($0) },
                navigation: navigation
            )
        }
        let controller = UIHostingController(rootView: list(paired: false))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        var fetched = fetches.stream.makeAsyncIterator()
        // The unpaired host's first load has run (and failed).
        try #require(await fetched.next() != nil)
        controller.rootView = list(paired: true)
        frames.continuation.yield(.frame(.snapshot(pushed)))
        for _ in 0..<100 {
            if published.last == pushed { break }
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(published.last == pushed)
    }

    @Test("WorktreePickerView wrapper delegates to WorktreeListContent")
    func wrapperDelegates() {
        let h = sampleHost()
        let wrapper = WorktreePickerView(
            host: h,
            onSelect: { _ in },
            onSelectPane: { _, _ in }
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
/// An initial load the test completes by hand.
@MainActor
private final class HeldLoad {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
#endif
