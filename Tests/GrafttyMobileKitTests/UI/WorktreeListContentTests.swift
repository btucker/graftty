#if canImport(UIKit)
import Testing
import Foundation
import GrafttyProtocol
import GrafttyCommandUI
import SwiftUI
import UIKit
@testable import GrafttyMobileKit

@MainActor
@Suite("WorktreeListContent — extracted picker preserves callbacks")
struct WorktreeListContentTests {

    @Test("@spec IPAD-1.22: While the iPad split-view sidebar has a compact column size class, the application shall retain the project rail and select projects within the sidebar rather than push compact navigation destinations.", arguments: [true, false])
    func splitViewSidebarRetainsProjectSelection(collapsed: Bool) async throws {
        let suite = "ipad-project-selection-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SidebarLayoutPolicy.projectRailSettingKey)
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults, collapsed: collapsed)
        let rows = [sampleWorktree(path: "/repo/first")]
        let frames = AsyncStream<RemoteWorktreeUpdate>.makeStream()
        let feed = makeFeed(frames.stream)
        frames.continuation.yield(.frame(.snapshot(rows)))
        let controller = UIHostingController(rootView: WorktreeListContent(
            feed: feed, isSidebar: true,
            onSelect: { _, _ in }, onSelectPane: { _, _, _ in }, navigation: navigation
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
        let step = ProjectStep(project: project)
        let feed = MultiHostFeed(coordinator: nil)
        let root = WorktreePickerView(feed: feed,
            onSelect: { _, _ in }, onSelectPane: { _, _, _ in })
        let destination = WorktreePickerView(feed: feed,
            onSelect: { _, _ in }, onSelectPane: { _, _, _ in }, project: step.project)
        #expect(root.project == nil)
        #expect(destination.project?.id == "repo")
        let navigation = SidebarNavigationState(prefix: "project-route-\(UUID())")
        navigation.showProject("different-project")
        // Changing shared sidebar selection must not replace either stack level.
        #expect(root.project == nil)
        #expect(destination.project?.id == "repo")
    }

    @Test("A compact destination naming one host's project lists the merged project's rows", .timeLimit(.minutes(1)))
    func destinationNamingAMemberProjectListsRows() async throws {
        let suite = "worktree-member-destination-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let member = SidebarProject(id: "member", repositoryID: "/repo", name: "repo", originKey: "github.com/acme/repo")
        let row = WorktreePanes(path: "/repo/first", displayName: "first", repoDisplayName: "repo", displayBranch: "main", state: .running,
            isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            sidebar: SidebarWorktreeMetadata(id: "member:first", projectID: member.id))
        let frames = AsyncStream<RemoteWorktreeUpdate>.makeStream()
        frames.continuation.yield(.frame(.snapshot([row], sidebar: SidebarSnapshot(projects: [member]))))
        let hosted = try host(WorktreeListContent(
            feed: makeFeed(frames.stream),
            onSelect: { _, _ in }, onSelectPane: { _, _, _ in },
            navigation: SidebarNavigationState(prefix: "test", defaults: defaults, collapsed: true),
            project: member
        ), defaults: defaults)
        defer { hosted.isHidden = true }
        try await waitUntilRendered(hosted, ["first"])
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

    /// A feed reading one host's frames, with no real connections.
    private func makeFeed(_ stream: AsyncStream<RemoteWorktreeUpdate>) -> MultiHostFeed {
        let feed = MultiHostFeed(coordinator: nil, updates: { _ in stream })
        feed.setHosts([sampleHost()])
        Task { await feed.observe() }
        return feed
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

    @Test("@spec IOS-4.52: While a paired host's worktree list is displayed, when the host pushes a changed panes-state frame, the application shall render it without fetching the list again.", .timeLimit(.minutes(1)))
    func pushedFrameUpdatesTheListWithoutAFetch() async throws {
        let suite = "worktree-push-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = [sampleWorktree(path: "/repo/first")]
        let pushed = initial + [sampleWorktree(path: "/repo/second")]
        let frames = AsyncStream<RemoteWorktreeUpdate>.makeStream()
        frames.continuation.yield(.frame(.snapshot(initial)))
        let hosted = try host(WorktreeListContent(
            feed: makeFeed(frames.stream),
            onSelect: { _, _ in }, onSelectPane: { _, _, _ in },
            navigation: SidebarNavigationState(prefix: "test", defaults: defaults, collapsed: true)
        ), defaults: defaults)
        defer { hosted.isHidden = true }

        try await waitUntilRendered(hosted, ["first"])
        frames.continuation.yield(.frame(.snapshot(pushed)))
        try await waitUntilRendered(hosted, ["first", "second"])
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

    /// The list as hosted tests render it: flat rows (no project rail) with
    /// an accessibility tree to read row names from.
    private func rendered(_ list: WorktreeListContent, defaults: UserDefaults) -> some View {
        list.defaultAppStorage(defaults)
            .accessibilityElement(children: .contain)
            .environment(\.accessibilityEnabled, true)
    }

    private func host(_ list: WorktreeListContent, defaults: UserDefaults) throws -> UIWindow {
        defaults.set(false, forKey: SidebarLayoutPolicy.projectRailSettingKey)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        window.rootViewController = UIHostingController(rootView: rendered(list, defaults: defaults))
        window.makeKeyAndVisible()
        return window
    }

    /// Worktree display names the hosted list currently renders.
    private func renderedNames(in window: UIWindow) -> Set<String> {
        guard let root = window.rootViewController?.view else { return [] }
        root.layoutIfNeeded()
        var names: Set<String> = [], pending: [NSObject] = [root], seen: Set<ObjectIdentifier> = []
        while let object = pending.popLast(), seen.count < 4096 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if let label = object.accessibilityLabel { names.insert(label) }
            if let view = object as? UIView { pending.append(contentsOf: view.subviews) }
            pending.append(contentsOf: (object.accessibilityElements ?? []).compactMap { $0 as? NSObject })
            for index in 0..<max(0, min(object.accessibilityElementCount(), 128)) {
                if let child = object.accessibilityElement(at: index) as? NSObject { pending.append(child) }
            }
        }
        return names
    }

    /// Hosted rendering is asynchronous; wait a bounded time for the rows.
    private func waitUntilRendered(_ window: UIWindow, _ names: [String],
                                   sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<150 {
            if renderedNames(in: window).isSuperset(of: names) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Rows \(names) were not rendered", sourceLocation: sourceLocation)
        throw CancellationError()
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
