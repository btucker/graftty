import Foundation
import GrafttyCommandUI
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@Suite("Pane Attention navigation")
@MainActor
struct MobilePaneAttentionTests {
    @Test("@spec IOS-4.34: While a mobile pane is open, its back button shall badge pending worktrees elsewhere and navigate to the next pending worktree and project when tapped with a nonzero badge.")
    func countsOtherWorktreesAndNavigatesDirectly() {
        let navigation = SidebarNavigationState(prefix: "pane-attention.\(UUID())")
        let current = worktree("current")
        let other = worktree("other")
        let viewed = worktree("viewed")
        let completedCommand = worktree("command", source: .commandFinished)
        let rows = [current, other, viewed, completedCommand]
        navigation.opened(SidebarProjection.activity([viewed])[0])
        #expect(MobilePaneAttention.pendingCount(worktrees: rows, currentWorktree: current.path, navigation: navigation) == 1)
        navigation.filter = .running
        navigation.query = "old search"
        MobilePaneAttention.open(worktrees: rows, projects: SidebarProjection.projects(rows), navigation: navigation)
        #expect(navigation.selectedProjectID == "project")
        #expect(navigation.rememberedWorktrees["project"] == current.path)
        #expect(navigation.query.isEmpty)
        #expect(MobilePaneAttention.pendingCount(worktrees: [current, viewed, completedCommand], currentWorktree: current.path, navigation: navigation) == 0)
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
        #expect(MobilePaneAttention.pendingCount(worktrees: rows + [rows[1]], currentWorktree: "/third", navigation: navigation) == 1)
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
                          isPinned: Bool? = nil, folders: [String] = []) -> WorktreePanes {
        WorktreePanes(path: "/\(name)", displayName: name, repoDisplayName: "Project", displayBranch: name,
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil,
            attentionText: source == .commandFinished ? "Done" : nil,
            attentionSource: source == .commandFinished ? source : nil, layout: nil,
            sidebar: .init(id: name, projectID: "project", folders: folders, unseenAgentStop: source == .agentStop
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
