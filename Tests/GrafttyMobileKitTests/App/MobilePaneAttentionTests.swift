import Foundation
import GrafttyCommandUI
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit
#if canImport(UIKit)
import SwiftUI
#endif

@Suite("Pane Attention navigation")
@MainActor
struct MobilePaneAttentionTests {
    @Test("Pending attention counts other worktrees and opens a separate pending route")
    func countsOtherWorktreesAndNavigatesDirectly() {
        let navigation = SidebarNavigationState(prefix: "pane-attention.\(UUID())")
        defer { MobilePaneAttention.consumePendingRoute(for: navigation) }
        let current = worktree("current")
        let other = worktree("other")
        let viewed = worktree("viewed")
        let completedCommand = worktree("command", source: .commandFinished)
        let rows = [current, other, viewed, completedCommand]
        navigation.opened(SidebarProjection.activity([viewed])[0])
        #expect(MobilePaneAttention.pendingCount(worktrees: rows, currentWorktree: current.path, navigation: navigation) == 2)
        navigation.filter = .running
        navigation.query = "old search"
        MobilePaneAttention.open(worktrees: rows, projects: SidebarProjection.projects(rows), navigation: navigation)
        #expect(navigation.selectedProjectID == "project")
        #expect(navigation.rememberedWorktrees["project"] == current.path)
        #expect(navigation.query.isEmpty)
        #expect(MobilePaneAttention.pendingCount(worktrees: [current, viewed, completedCommand], currentWorktree: current.path, navigation: navigation) == 1)
    }

    @Test("A new stop at a previously viewed worktree counts again")
    func newerOccurrenceCounts() {
        let navigation = SidebarNavigationState(prefix: "pane-attention.\(UUID())")
        let first = worktree("other")
        navigation.opened(SidebarProjection.activity([first])[0])
        let next = worktree("other", stoppedAt: 110)
        #expect(MobilePaneAttention.pendingCount(worktrees: [next], currentWorktree: "/current", navigation: navigation) == 1)
    }

    @Test("@spec LAYOUT-2.143: When mobile pending navigation is invoked, the application shall visit pending worktrees in displayed host order, wrap after the last worktree, and route to its project without entering Attention mode.")
    func pendingNavigationUsesWorktreeOrderAndWraps() {
        let navigation = SidebarNavigationState(prefix: "mobile-pending.\(UUID())")
        let rows = [worktree("first"), worktree("second"), worktree("third")]
        let projects = SidebarProjection.projects(rows)
        let next = MobilePaneAttention.open(worktrees: rows, projects: projects,
            navigation: navigation, currentWorktree: "/second")
        #expect(next?.worktreeID == "/third")
        #expect(MobilePaneAttention.pendingRoute(for: navigation)?.worktreeID == "/third")
        MobilePaneAttention.consumePendingRoute(for: navigation)
        #expect(MobilePaneAttention.pendingRoute(for: navigation) == nil)
        let wrap = MobilePaneAttention.open(worktrees: rows, projects: projects,
            navigation: navigation, currentWorktree: "/third")
        #expect(wrap?.worktreeID == "/first")
        navigation.opened(SidebarProjection.activity([rows[0]])[0])
        #expect(MobilePaneAttention.pendingCount(worktrees: rows + [rows[1]], currentWorktree: "/third", navigation: navigation) == 2)
        #expect(navigation.nextPendingWorktree(in: rows, projectID: "other-project", after: nil) == nil)
        #expect(MobilePaneAttention.open(worktrees: [rows[2]], projects: projects,
            navigation: navigation, currentWorktree: rows[2].path)?.worktreeID == rows[2].path)
        MobilePaneAttention.consumePendingRoute(for: navigation)
    }

    @Test("Pending traversal follows pinned sections and contiguous folder descendants")
    func pendingTraversalUsesRenderedFolderOrder() {
        let navigation = SidebarNavigationState(prefix: "mobile-folders.\(UUID())")
        let first = worktree("first", folders: ["feature"])
        let outside = worktree("outside")
        let sibling = worktree("sibling", folders: ["feature"])
        let pinned = worktree("pinned", isPinned: true)
        let rows = [first, outside, sibling, pinned]
        #expect(MobilePaneAttention.displayedWorktrees(rows).map(\.path) == [pinned.path, first.path, sibling.path, outside.path])
        #expect(MobilePaneAttention.open(worktrees: rows, projects: SidebarProjection.projects(rows),
            navigation: navigation, currentWorktree: first.path)?.worktreeID == sibling.path)
        MobilePaneAttention.consumePendingRoute(for: navigation)
    }

    @Test("Pending navigation includes all displayed projects when the project rail is hidden")
    func hiddenRailIncludesOtherProjects() {
        let navigation = SidebarNavigationState(prefix: "mobile-all-projects.\(UUID())")
        let selected = worktree("selected")
        let other = worktree("other", projectID: "other-project")
        navigation.showProject("project")
        navigation.opened(SidebarProjection.activity([selected])[0])
        let rows = [selected, other]
        let projectID = SidebarLayoutPolicy.projectFilter(selectedID: navigation.selectedProjectID, showsProjectRail: false)
        let scopedRows = rows.filter { projectID == nil || SidebarProjection.projectID($0) == projectID }
        #expect(MobilePaneAttention.pendingCount(worktrees: scopedRows, currentWorktree: nil, navigation: navigation) == 2)
        #expect(navigation.nextPendingWorktree(in: rows, projectID: projectID, after: selected.path)?.worktreeID == other.path)
        #expect(navigation.nextPendingWorktree(in: rows, projectID: navigation.selectedProjectID, after: selected.path)?.worktreeID == selected.path)
    }

    @Test("Opening a worktree with an old recap targets its new pending request")
    func livePendingRequestWinsOverRetainedRecap() {
        let navigation = SidebarNavigationState(prefix: "mobile-target.\(UUID())")
        let row = worktree("first")
        let report = navigation.worktreeContext(row).item
        navigation.opened(report)
        let notified = WorktreePanes(path: row.path, displayName: row.displayName, repoDisplayName: row.repoDisplayName,
            displayBranch: row.displayBranch, state: .running, isMainCheckout: false, prBadge: nil, stats: nil,
            attentionText: "Answer the new question", attentionSource: .userNotify, layout: nil,
            sidebar: .init(id: "first", projectID: "project", attentionTimestamps: ["worktree": 120]))
        let context = navigation.worktreeContext(notified)
        #expect(context.item.agentStop != nil)
        #expect(MobilePaneAttention.openTarget(for: context).title == "Answer the new question")
    }

    private func worktree(_ name: String, source: AttentionSource = .agentStop, stoppedAt: TimeInterval = 100,
                          isPinned: Bool? = nil, folders: [String] = [], projectID: String = "project") -> WorktreePanes {
        WorktreePanes(path: "/\(name)", displayName: name, repoDisplayName: "Project", displayBranch: name,
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil,
            attentionText: source == .commandFinished ? "Done" : nil,
            attentionSource: source == .commandFinished ? source : nil, layout: nil,
            sidebar: .init(id: name, projectID: projectID, folders: folders, unseenAgentStop: source == .agentStop
                ? .init(agentName: "Codex", stoppedAt: Date(timeIntervalSince1970: stoppedAt)) : nil, isPinned: isPinned))
    }
}

struct SidebarWorktreeReportOrderTests {
    @Test("@spec LAYOUT-2.140: While a mobile worktree report is displayed, the application shall freeze host-published project and worktree positions and folder and pin membership while keeping report and row content live.")
    func freezesPositionsAndMembershipOnly() {
        let first = row("first", project: "a")
        let second = row("second", project: "b")
        let projects = SidebarProjection.projects([first, second])
        let order = SidebarWorktreeReportOrder(worktrees: [first, second], projects: projects)
        let changed = row("first", project: "a", displayName: "Updated title",
            attentionText: "New question", isPinned: true, folders: ["New folder"])
        let added = row("added", project: "a")
        let result = order.orderedWorktrees([second, changed, added])
        #expect(result.map(\.path) == [first.path, second.path, added.path])
        #expect(result[0].displayName == "Updated title")
        #expect(result[0].attentionText == "New question")
        #expect(result[0].sidebar?.isPinned == false)
        #expect(result[0].sidebar?.folders == [])
        #expect(order.orderedProjects(projects.reversed()).map(\.id) == projects.map(\.id))
        #expect(order.orderedWorktrees([second]).map(\.path) == [second.path])
    }

    @Test("Frozen positions distinguish equal paths belonging to different projects")
    func opaqueOwnerRoutesRemainDistinct() {
        let first = row("same", project: "a")
        let second = row("same", project: "b", displayName: "Remote")
        let order = SidebarWorktreeReportOrder(worktrees: [first, second], projects: [])
        #expect(order.orderedWorktrees([second, first]).map(\.displayName) == ["same", "Remote"])
    }

    private func row(_ name: String, project: String, displayName: String? = nil,
                     attentionText: String? = nil, isPinned: Bool = false, folders: [String] = []) -> WorktreePanes {
        WorktreePanes(path: "/\(name)", displayName: displayName ?? name, repoDisplayName: project,
            displayBranch: name, state: .running, isMainCheckout: false,
            prBadge: nil, stats: nil, attentionText: attentionText, layout: nil,
            sidebar: .init(id: name, projectID: project, folders: folders, isPinned: isPinned))
    }
}

#if canImport(UIKit)
@MainActor
@Suite("@spec IOS-4.34: When the user taps Back from a mobile terminal, the application shall return to the worktree list regardless of pending work, preserving pending-work navigation as a separate action.")
struct TerminalBackNavigationTests {
    @Test(arguments: [false, true], [false, true])
    func returnsToProjectWorktrees(hasPendingWork: Bool, throughPaneDetail: Bool) {
        let host = Host(label: "Mac", baseURL: URL(string: "https://mac.local")!)
        let current = worktree("current", pending: false)
        let other = worktree("other", pending: hasPendingWork)
        let navigation = SidebarNavigationState(prefix: "terminal-back.\(UUID())")
        let project = SidebarProjection.projects([current, other])[0]
        navigation.showProject(project.id)
        navigation.query = "keep this search"
        let step = SessionStep(host: host, worktreePath: current.path, sessionName: "s", title: "Shell",
                               worktreeProject: project)
        var pickerPath = NavigationPath()
        pickerPath.append(host)
        pickerPath.append(ProjectStep(host: host, project: project))
        var path = pickerPath
        if throughPaneDetail { path.append(WorktreeStep(host: host, worktree: current)) }
        path.append(step)
        let view = SingleSessionView(step: step, navigationPath: Binding(get: { path }, set: { path = $0 }),
                                     sidebarNavigation: navigation, attentionWorktrees: [current, other])

        view.popToParent()

        #expect(path == pickerPath)
        #expect(MobilePaneAttention.pendingRoute(for: navigation) == nil)
        #expect(navigation.query == "keep this search")
        #expect(navigation.rememberedWorktrees[project.id] == nil)
        #expect(view.backAccessibilityLabel == (hasPendingWork
            ? "Back to worktrees, 1 pending worktree" : "Back to worktrees"))
        MobilePaneAttention.consumePendingRoute(for: navigation)
    }

    @Test(arguments: [false, true])
    func returnsToHostWorktreesWithoutAProject(throughPaneDetail: Bool) {
        let host = Host(label: "Mac", baseURL: URL(string: "https://mac.local")!)
        let current = worktree("current", pending: false)
        let step = SessionStep(host: host, worktreePath: current.path, sessionName: "s", title: "Shell")
        var pickerPath = NavigationPath()
        pickerPath.append(host)
        var path = pickerPath
        if throughPaneDetail { path.append(WorktreeStep(host: host, worktree: current)) }
        path.append(step)
        let view = SingleSessionView(step: step, navigationPath: Binding(get: { path }, set: { path = $0 }))

        view.popToParent()

        #expect(path == pickerPath)
    }

    @Test(arguments: [false, true])
    func ipadBackUsesTheWorktreeListCallback(hasPendingWork: Bool) {
        let host = Host(label: "Mac", baseURL: URL(string: "https://mac.local")!)
        let current = worktree("current", pending: false)
        let other = worktree("other", pending: hasPendingWork)
        let navigation = SidebarNavigationState(prefix: "ipad-back.\(UUID())")
        let appState = IPadAppState(defaults: UserDefaults(suiteName: "ipad-back.\(UUID())")!)
        appState.selectedWorktreePath = current.path
        appState.focusedPaneId = "s"
        appState.columnVisibility = .detailOnly
        var path = NavigationPath()
        var callbackCount = 0
        let view = SingleSessionView(
            step: SessionStep(host: host, worktreePath: current.path, sessionName: "s", title: "Shell"),
            navigationPath: Binding(get: { path }, set: { path = $0 }),
            isFullScreen: false, isEmbeddedPane: true,
            onBackToWorktrees: {
                callbackCount += 1
                IPadRootLayout.applyBackToWorktrees(appState: appState)
            },
            sidebarNavigation: navigation, attentionWorktrees: [current, other])

        view.popToParent()

        #expect(callbackCount == 1)
        #expect(appState.selectedWorktreePath == nil)
        #expect(appState.focusedPaneId == nil)
        #expect(appState.columnVisibility == .all)
        #expect(path.isEmpty)
        #expect(MobilePaneAttention.pendingRoute(for: navigation) == nil)
        MobilePaneAttention.consumePendingRoute(for: navigation)
    }

    @Test
    func emptyNavigationPathIsSafe() {
        let host = Host(label: "Mac", baseURL: URL(string: "https://mac.local")!)
        var path = NavigationPath()
        let view = SingleSessionView(step: SessionStep(host: host, sessionName: "s", title: "Shell"),
                                     navigationPath: Binding(get: { path }, set: { path = $0 }))
        view.popToParent()
        #expect(path.isEmpty)
    }

    @Test(arguments: [false, true])
    func adaptiveLayoutBackReachesWorktrees(showsProjectRail: Bool) throws {
        let host = Host(label: "Mac", baseURL: URL(string: "https://mac.local")!)
        let current = worktree("current", pending: false,
            layout: .leaf(sessionName: "s", title: "Shell", attentionText: nil, isBusy: false, attentionSource: nil))
        let state = IPadAppState(defaults: UserDefaults(suiteName: "adaptive-back.\(UUID())")!)
        state.selectedHostId = host.id
        state.selectedWorktreePath = current.path
        state.focusedPaneId = "s"
        state.latestWorktrees = [current]
        let selection = try #require(RootView.compactSelection(appState: state, hosts: [host],
                                                             showsProjectRail: showsProjectRail))
        let step = try #require(selection.session)
        var path = selection.path
        var pickerPath = NavigationPath()
        pickerPath.append(host)
        if showsProjectRail {
            pickerPath.append(ProjectStep(host: host, project: SidebarProjection.projects([current])[0]))
        }
        let view = SingleSessionView(step: step, navigationPath: Binding(get: { path }, set: { path = $0 }),
                                     showsProjectRail: showsProjectRail)

        view.popToParent()

        #expect(path == pickerPath)
    }

    @Test(arguments: [false, true], [false, true])
    func compactBackPreservesThePickerAcrossLayouts(openingRail: Bool, currentRail: Bool) throws {
        let host = Host(label: "Mac", baseURL: URL(string: "https://mac.local")!)
        let current = worktree("current", pending: false,
            layout: .leaf(sessionName: "s", title: "Shell", attentionText: nil, isBusy: false, attentionSource: nil))
        let other = worktree("other", pending: true)
        let rows = [current, other]
        let project = SidebarProjection.projects(rows)[0]
        let navigation = SidebarNavigationState(prefix: "compact-back-state.\(UUID())")
        navigation.showProject(project.id)
        navigation.query = "keep this search"
        navigation.rememberedWorktrees[project.id] = current.path
        let state = IPadAppState(defaults: UserDefaults(suiteName: "compact-back-state.\(UUID())")!)
        state.sidebarNavigation = navigation
        state.selectedHostId = host.id
        state.selectedWorktreePath = current.path
        state.focusedPaneId = "s"
        state.latestWorktrees = rows
        let openingSelection = try #require(RootView.compactSelection(appState: state, hosts: [host],
                                                                    showsProjectRail: openingRail))
        let step = try #require(openingSelection.session)
        var path = openingSelection.path
        var pickerPath = NavigationPath()
        pickerPath.append(host)
        if currentRail { pickerPath.append(ProjectStep(host: host, project: project)) }
        let pendingBefore = MobilePaneAttention.pendingCount(worktrees: rows, currentWorktree: nil,
                                                           navigation: navigation)
        let view = SingleSessionView(
            step: step, navigationPath: Binding(get: { path }, set: { path = $0 }),
            onBackToWorktrees: {
                RootView.applyCompactBack(step: step, appState: state, navigationPath: &path,
                                          showsProjectRail: currentRail)
            },
            sidebarNavigation: navigation, attentionWorktrees: rows)

        view.popToParent()

        #expect(path == pickerPath)
        #expect(state.selectedHostId == host.id)
        #expect(state.selectedWorktreePath == nil)
        #expect(state.focusedPaneId == nil)
        #expect(navigation.selectedProjectID == project.id)
        #expect(navigation.query == "keep this search")
        #expect(navigation.rememberedWorktrees[project.id] == current.path)
        #expect(MobilePaneAttention.pendingRoute(for: navigation) == nil)
        #expect(MobilePaneAttention.pendingCount(worktrees: rows, currentWorktree: nil,
                                               navigation: navigation) == pendingBefore)
        let returningSelection = try #require(RootView.compactSelection(appState: state, hosts: [host],
                                                                      showsProjectRail: currentRail))
        #expect(returningSelection.session == nil)
        #expect(returningSelection.worktree == nil)
        #expect(returningSelection.path == pickerPath)
    }

    @Test(arguments: [false, true], [false, true])
    func originatingProjectAcrossSearch(throughPaneDetail: Bool, adaptiveRoundTrip: Bool) throws {
        let host = Host(label: "Mac", baseURL: URL(string: "https://mac.local")!)
        let origin = worktree("origin", pending: false, projectID: "project-a")
        let current = worktree("search-result", pending: false,
            layout: .leaf(sessionName: "s", title: "Shell", attentionText: nil, isBusy: false, attentionSource: nil),
            projectID: "project-b")
        let pickerProject = SidebarProjection.projects([origin])[0]
        let currentProject = SidebarProjection.projects([current])[0]
        let navigation = SidebarNavigationState(prefix: "search-back.\(UUID())")
        navigation.showProject(pickerProject.id)
        navigation.query = "search-result"
        // Selecting a search result remembers its project while the visible
        // picker destination still belongs to the originating project.
        navigation.selectedProjectID = currentProject.id
        navigation.rememberedWorktrees[currentProject.id] = current.path
        let state = IPadAppState(defaults: UserDefaults(suiteName: "search-back.\(UUID())")!)
        state.sidebarNavigation = navigation
        state.selectedHostId = host.id
        state.selectedWorktreePath = current.path
        state.focusedPaneId = "s"
        state.latestWorktrees = [origin, current]
        var step = SessionStep(host: host, worktreePath: current.path, sessionName: "s", title: "Shell",
                               worktreeProject: pickerProject)
        var pickerPath = NavigationPath()
        pickerPath.append(host)
        pickerPath.append(ProjectStep(host: host, project: pickerProject))
        var path = pickerPath
        if throughPaneDetail {
            path.append(WorktreeStep(host: host, worktree: current, project: pickerProject))
        }
        path.append(step)
        RootView.applyCompactSession(step, to: state)
        if adaptiveRoundTrip {
            let selection = try #require(RootView.compactSelection(appState: state, hosts: [host]))
            step = try #require(selection.session)
            path = selection.path
        }
        let view = SingleSessionView(
            step: step, navigationPath: Binding(get: { path }, set: { path = $0 }),
            onBackToWorktrees: {
                RootView.applyCompactBack(step: step, appState: state, navigationPath: &path,
                                          showsProjectRail: true)
            },
            sidebarNavigation: navigation)

        view.popToParent()

        #expect(path == pickerPath)
        #expect(navigation.selectedProjectID == pickerProject.id)
        #expect(navigation.query == "search-result")
        #expect(navigation.rememberedWorktrees[currentProject.id] == current.path)
        #expect(state.selectedWorktreePath == nil)
        #expect(state.focusedPaneId == nil)
        let returningSelection = try #require(RootView.compactSelection(appState: state, hosts: [host]))
        #expect(returningSelection.path == pickerPath)
        #expect(returningSelection.session == nil)
        #expect(returningSelection.worktree == nil)

        navigation.showProject(currentProject.id)
        let laterSelection = try #require(RootView.compactSelection(appState: state, hosts: [host]))
        #expect(laterSelection.project?.id == currentProject.id)
    }

    @Test(arguments: [false, true])
    func pickerSurvivesLayoutChangesBeforeListLoads(showsProjectRail: Bool) throws {
        let host = Host(label: "Mac", baseURL: URL(string: "https://mac.local")!)
        let current = worktree("current", pending: false)
        let project = SidebarProjection.projects([current])[0]
        let state = IPadAppState(defaults: UserDefaults(suiteName: "back-before-fetch.\(UUID())")!)
        state.selectedHostId = host.id
        state.selectedWorktreePath = current.path
        state.focusedPaneId = "s"
        state.sidebarNavigation.showProject(project.id)
        // Compact pickers fetch independently. The shared iPad list has not
        // loaded yet, so Back must retain its originating project itself.
        #expect(state.latestWorktrees.isEmpty)
        let step = SessionStep(host: host, worktreePath: current.path, sessionName: "s", title: "Shell",
                               worktreeProject: project)
        var path = NavigationPath()
        path.append(host)
        path.append(step)
        let view = SingleSessionView(step: step, navigationPath: Binding(get: { path }, set: { path = $0 }),
            onBackToWorktrees: {
                RootView.applyCompactBack(step: step, appState: state, navigationPath: &path,
                                          showsProjectRail: showsProjectRail)
            })
        view.popToParent()
        let returningSelection = try #require(RootView.compactSelection(appState: state, hosts: [host],
                                                                      showsProjectRail: showsProjectRail))
        #expect(returningSelection.path == path)
        #expect(returningSelection.session == nil)
        #expect(returningSelection.worktree == nil)

        let otherHost = Host(label: "Other Mac", baseURL: URL(string: "https://other.local")!)
        RootView.applyCompactHost(otherHost, to: state)
        let otherSelection = try #require(RootView.compactSelection(appState: state, hosts: [otherHost]))
        #expect(otherSelection.project == nil)
    }

    private func worktree(_ name: String, pending: Bool, layout: PaneLayoutNode? = nil,
                          projectID: String = "project") -> WorktreePanes {
        WorktreePanes(path: "/\(name)", displayName: name, repoDisplayName: "Project", displayBranch: name,
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: layout,
            sidebar: .init(id: name, projectID: projectID, unseenAgentStop: pending
                ? .init(agentName: "Codex", stoppedAt: Date(timeIntervalSince1970: 100)) : nil))
    }
}
#endif
