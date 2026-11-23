import Foundation
import Testing
@testable import GrafttyProtocol

struct WorkspaceLayoutTests {
    /// Two stage panes: `a` (with `b` off stage behind it) and `other`.
    private func twoPaneLayout() throws -> (WorkspaceLayout<String>, UUID, UUID) {
        var layout = WorkspaceLayout<String>()
        for session in ["a", "b", "other"] { layout.addAgent(session) }
        let first = try #require(layout.groups.first?.id)
        layout.split("other", beside: first, edge: .right)
        layout.select("a")
        let second = try #require(layout.group(containing: "other")?.id)
        return (layout, first, second)
    }

    @Test("@spec LAYOUT-2.247: When the user puts an off-stage agent on stage, the application shall show it in the focused stage pane and keep the agent it replaces in the gallery off stage.")
    func stagingReplacesFocusedPane() throws {
        var (layout, first, _) = try twoPaneLayout()
        layout.addAgent("c"); layout.select("a")
        #expect(!layout.isOnStage("c"))
        layout.stage("c")
        #expect(layout.isOnStage("c"))
        #expect(!layout.isOnStage("a"))
        #expect(layout.group(containing: "c")?.id == first)
        #expect(layout.focusedSession == "c")
        #expect(Set(layout.gallerySessions) == ["a", "b", "c", "other"])
    }

    @Test("@spec LAYOUT-2.248: When the user puts an agent on stage that is already on stage in another pane, the application shall focus that pane and shall not show the agent twice.")
    func stagingAnOnStageAgentFocusesIt() throws {
        var (layout, _, second) = try twoPaneLayout()
        let groups = layout.groups
        layout.stage("other")
        #expect(layout.groups == groups)
        #expect(layout.focusedSession == "other")
        #expect(layout.focusedGroupID == second)
    }

    @Test("@spec LAYOUT-2.249: When the user removes a pane from a split stage, the application shall keep its agents in the gallery off stage, leave the remaining panes unchanged, and refuse to remove the last pane.")
    func removingAPaneKeepsItsAgents() throws {
        var (layout, first, second) = try twoPaneLayout()
        layout.select("other")
        let removed = layout.removePane(second)
        #expect(removed)
        #expect(layout.groups.count == 1)
        #expect(layout.groups[0].selected == "a")
        #expect(!layout.isOnStage("other"))
        #expect(Set(layout.gallerySessions) == ["a", "b", "other"])
        #expect(layout.focusedSession == "a")
        let removedLast = layout.removePane(first)
        #expect(!removedLast)
        #expect(layout.groups.count == 1)
    }

    @Test("@spec LAYOUT-2.250: When the user drags a gallery tile before or after another, the application shall persist the new tile order, keep it across stage changes, and leave what is on stage and keyboard focus unchanged.")
    func tileOrderIsIndependentOfStage() throws {
        var (layout, _, _) = try twoPaneLayout()
        layout.addAgent("c"); layout.select("a")
        #expect(layout.gallerySessions == ["a", "b", "other", "c"])
        let before = layout
        let moved = layout.moveTile("c", relativeTo: "a", after: false)
        #expect(moved)
        #expect(layout.gallerySessions == ["c", "a", "b", "other"])
        #expect(layout.groups == before.groups)
        #expect(layout.focusedSession == before.focusedSession)
        layout.stage("b")
        layout.split("c", beside: layout.groups[0].id, edge: .bottom)
        #expect(layout.gallerySessions == ["c", "a", "b", "other"])
        let sameTile = layout.moveTile("c", relativeTo: "c", after: true)
        let missing = layout.moveTile("absent", relativeTo: "a", after: true)
        #expect(!sameTile && !missing)
        let restored = try JSONDecoder().decode(WorkspaceLayout<String>.self, from: JSONEncoder().encode(layout))
        #expect(restored == layout)
    }

    @Test func layoutsSavedBeforeTheGalleryDecodeInCanvasOrder() throws {
        let legacy = WorkspaceLayout<String>(root: .group(UUID()), groups: [])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "storedGalleryOrder"); json.removeValue(forKey: "galleryVisible")
        var layout = try JSONDecoder().decode(WorkspaceLayout<String>.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(layout.galleryVisible == nil)
        let (populated, _, _) = try twoPaneLayout()
        var stripped = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(populated)) as? [String: Any])
        stripped.removeValue(forKey: "storedGalleryOrder")
        layout = try JSONDecoder().decode(WorkspaceLayout<String>.self, from: JSONSerialization.data(withJSONObject: stripped))
        #expect(layout.gallerySessions == layout.canvasSessions)
    }

    @Test func removingTheStagedAgentStagesAnother() throws {
        var (layout, _, _) = try twoPaneLayout()
        layout.remove("a")
        #expect(layout.isOnStage("b"))
        #expect(!layout.gallerySessions.contains("a"))
    }

    @Test func galleryShowsByItselfFromTheSecondAgent() {
        var layout = WorkspaceLayout<String>()
        #expect(!layout.showsGallery(agentCount: 1))
        #expect(layout.showsGallery(agentCount: 2))
        layout.galleryVisible = false
        #expect(!layout.showsGallery(agentCount: 3))
        layout.galleryVisible = true
        #expect(layout.showsGallery(agentCount: 1))
    }

    @Test func tabDropTransfersAcrossGroupsAndRejectsStaleTargets() throws {
        var layout = WorkspaceLayout<String>()
        for session in ["a", "b", "c"] { layout.addAgent(session) }
        let group = try #require(layout.groups.first?.id)
        layout.split("c", beside: group, edge: .right)
        let transferred = layout.moveTab("c", relativeTo: "b", after: false)
        #expect(transferred)
        #expect(layout.groups.count == 1)
        #expect(layout.groups[0].sessions == ["a", "c", "b"])
        #expect(layout.groups[0].selected == "c")
        let before = layout
        let missingSource = layout.moveTab("absent", relativeTo: "a", after: true)
        let missingTarget = layout.moveTab("a", relativeTo: "absent", after: true)
        let sameTab = layout.moveTab("a", relativeTo: "a", after: true)
        #expect(!missingSource && !missingTarget && !sameTab)
        #expect(layout == before)
    }

    @Test("@spec AGENT-6.142: When a completed tab is dismissed before its terminal is cleaned up, the application shall preserve that dismissal across inventory updates and allow explicit reopening.")
    func dismissedCompletionStaysDismissed() throws {
        var layout = WorkspaceLayout<String>()
        layout.addAgent("done"); layout.addAgent("live"); layout.select("done")
        layout.remove("done")
        layout.reconcile(live: ["done", "live"], agents: ["done", "live"], completed: ["done"], preservingSelection: true)
        #expect(layout.sessions == ["live"])
        #expect(layout.focusedSession == "live")
        layout.addAgent("done"); layout.select("done")
        #expect(layout.focusedSession == "done")
    }

    @Test("@spec AGENT-6.137: When a remote agent terminal is cleaned up, the application shall retain its selected tab and render its completed content without adding a dead session to the host inventory.")
    func retainedConversationRendersWithoutLiveInventory() throws {
        var layout = WorkspaceLayout<String>()
        layout.addAgent("session"); layout.select("session")
        let before = layout.root
        let agent = AgentSessionInfo(id: "agent", name: "Review", provider: "codex", status: "closed", sessionName: nil,
            completionID: "completion", retainedSessionName: "session", retainedSlotID: UUID().uuidString, canResume: true)
        layout.reconcile(live: [], agents: [], retained: ["session"], preservingSelection: true)
        let restored = try JSONDecoder().decode(WorkspaceLayout<String>.self, from: JSONEncoder().encode(layout))
        #expect(restored.root == before)
        #expect(restored.focusedSession == "session")
        #expect(restored.visiblePaneLayout(in: nil, retainedAgents: [agent])?.leaves.map(\.sessionName) == ["session"])
        layout.remove("session")
        layout.reconcile(live: [], agents: [], retained: ["session"], preservingSelection: true)
        #expect(layout.sessions.isEmpty)
    }

    @Test("@spec LAYOUT-2.179: When the user opens an empty terminal drawer, the application shall request its first terminal automatically; reopening a populated drawer shall reuse its selected terminal.")
    func openingDrawerRequestsFirstShell() {
        var layout = WorkspaceLayout<String>()
        layout.addAgent("agent")
        let needsCreation = layout.openDrawer()
        #expect(needsCreation)
        #expect(layout.drawerVisible)
        let duplicateOpen = layout.openDrawer()
        #expect(!duplicateOpen)
        layout.addTerminal("shell")
        #expect(layout.hideDrawer() == "agent")
        let reopen = layout.openDrawer()
        #expect(!reopen)
        #expect(layout.selectedTerminal == "shell")
        layout.remove("shell")
        _ = layout.hideDrawer()
        let afterClose = layout.openDrawer()
        #expect(afterClose)
    }

    @Test("@spec LAYOUT-2.175: When resizing a terminal drawer after its viewport shrinks, the application shall begin the adjustment at its rendered height and use the same viewport bounds for rendering and resizing.")
    func drawerResizeStartsAtVisibleHeight() {
        typealias Layout = WorkspaceLayout<String>
        #expect(Layout.clampedDrawerHeight(700, available: 600) == 420)
        #expect(Layout.resizedDrawerHeight(700, by: -40, available: 600) == 380)
        #expect(Layout.resizedDrawerHeight(700, by: 40, available: 600) == 420)
        #expect(Layout.clampedDrawerHeight(240, available: 100) == 70)
        #expect(Layout.clampedDrawerHeight(.nan, available: 600) == 240)
        #expect(Layout.clampedDrawerHeight(240, available: .infinity) == 0)
    }

    @Test("@spec LAYOUT-2.161: When an agent moves between tabs and split groups, the application shall preserve its session identity and keep each session in exactly one position.")
    func tabsAndSplitsPreserveSessions() throws {
        var layout = WorkspaceLayout<String>()
        layout.addAgent("a")
        layout.addAgent("b")
        let first = try #require(layout.groups.first?.id)
        #expect(layout.groups.count == 1)
        #expect(layout.groups[0].sessions == ["a", "b"])
        layout.split("b", beside: first, edge: .right)
        #expect(layout.groups.count == 2)
        #expect(Set(layout.sessions) == ["a", "b"])
        layout.move("b", to: first)
        #expect(layout.groups.count == 1)
        #expect(layout.sessions.count == 2)
        #expect(layout.groups[0].selected == "b")
    }

    @Test("@spec LAYOUT-2.162: When the terminal drawer is hidden, the application shall retain its sessions and selected terminal while restoring the previously selected agent.")
    func hidingDrawerRetainsShell() throws {
        var layout = WorkspaceLayout<String>()
        layout.addAgent("agent")
        layout.addTerminal("shell")
        layout.select("shell")
        #expect(layout.drawerVisible)
        #expect(layout.hideDrawer() == "agent")
        #expect(!layout.drawerVisible)
        #expect(layout.selectedTerminal == "shell")
        #expect(layout.terminals == ["shell"])
        let restored = try JSONDecoder().decode(WorkspaceLayout<String>.self, from: JSONEncoder().encode(layout))
        #expect(restored == layout)
    }

    @Test("@spec LAYOUT-2.163: When workspace sessions close or appear, the application shall remove stale view references, collapse empty groups, and place new agents in tabs and new shells in the terminal drawer.")
    func reconcileInventory() {
        var layout = WorkspaceLayout<String>()
        layout.addAgent("old")
        layout.reconcile(live: ["agent", "shell"], agents: ["agent"])
        #expect(layout.groups.count == 1)
        #expect(layout.groups[0].sessions == ["agent"])
        #expect(layout.terminals == ["shell"])
        layout.reconcile(live: [], agents: [])
        #expect(layout.groups.isEmpty)
        #expect(layout.root == nil)
        #expect(layout.terminals.isEmpty)
    }
    @Test("@spec LAYOUT-2.171: When a viewer receives newly discovered sessions, the application shall preserve its selected tabs and drawer state until a local selection changes them.")
    func passiveDiscoveryKeepsSelection() {
        var layout = WorkspaceLayout<String>()
        layout.addAgent("a"); layout.addTerminal("shell")
        _ = layout.hideDrawer()
        layout.reconcile(live: ["a", "b", "shell", "new-shell"], agents: ["a", "b"], preservingSelection: true)
        #expect(layout.groups.first?.selected == "a")
        #expect(layout.selectedTerminal == "shell")
        #expect(!layout.drawerVisible)
        #expect(Set(layout.sessions) == ["a", "b", "shell", "new-shell"])
    }

    @Test("@spec LAYOUT-2.172: When a host explicitly publishes an empty agent inventory, the application shall initially place its ordinary terminals in the drawer while preserving legacy layouts from hosts without agent metadata.")
    func emptyAgentInventoryMeansOrdinaryShells() {
        let inventory = PaneLayoutNode.leaf(sessionName: "shell", title: "", attentionText: nil, isBusy: false, attentionSource: nil)
        let modern = WorktreePanes(path: "/repo", displayName: "Main", repoDisplayName: "Repo", displayBranch: "main", state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil, layout: inventory, agents: [])
        let legacy = WorktreePanes(path: "/repo", displayName: "Main", repoDisplayName: "Repo", displayBranch: "main", state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil, layout: inventory)
        #expect(WorkspaceLayout<String>.initial(for: modern).terminals == ["shell"])
        #expect(WorkspaceLayout<String>.initial(for: modern).groups.isEmpty)
        #expect(WorkspaceLayout<String>.initial(for: legacy).groups.count == 1)
    }

    @Test("@spec LAYOUT-2.240: When a host identifies a launched agent after its pane already appeared as a terminal, the application shall move that session from the terminal drawer into the agent tabs, leaving agents the user started by hand in a shell in place.")
    func lateIdentifiedLaunchedAgentLeavesDrawer() {
        func snapshot(_ sessions: [String], agents: [AgentSessionInfo]) -> WorktreePanes {
            let leaves = sessions.map { PaneLayoutNode.leaf(sessionName: $0, title: "", attentionText: nil, isBusy: false, attentionSource: nil) }
            let inventory = leaves.dropFirst().reduce(leaves[0]) { .split(direction: .horizontal, ratio: 0.5, left: $0, right: $1) }
            return WorktreePanes(path: "/repo", displayName: "Main", repoDisplayName: "Repo", displayBranch: "main", state: .running,
                isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil, layout: inventory, agents: agents)
        }
        func agent(_ id: String, session: String?, launched: Bool?) -> AgentSessionInfo {
            AgentSessionInfo(id: id, name: id, provider: "claude", status: "running", sessionName: session, launched: launched)
        }
        // The launch's pane reaches the viewer before the host binds the agent to it.
        var layout = WorkspaceLayout<String>.initial(for: snapshot(["shell", "claude"],
            agents: [agent("a", session: nil, launched: true)]))
        layout.select("claude")
        #expect(layout.terminals == ["shell", "claude"])

        layout.reconcile(with: snapshot(["shell", "claude"], agents: [agent("a", session: "claude", launched: true)]),
            preservingSelection: true)
        #expect(layout.groups.map(\.sessions) == [["claude"]])
        #expect(layout.terminals == ["shell"])
        #expect(layout.focusedSession == "claude")

        // A provider started by hand in a drawer shell keeps its place.
        layout.reconcile(with: snapshot(["shell", "claude"], agents: [agent("a", session: "claude", launched: true),
            agent("o", session: "shell", launched: nil)]), preservingSelection: true)
        #expect(layout.terminals == ["shell"])
        #expect(layout.groups.map(\.sessions) == [["claude"]])
    }

    @Test func lateIdentifiedLaunchedAgentKeepsTheSelectedTabOfItsNewGroup() {
        // The drawer's selected terminal is identified while focus is on another agent tab.
        var layout = WorkspaceLayout<String>()
        layout.addAgent("x"); layout.addTerminal("claude")
        _ = layout.hideDrawer()
        layout.reconcile(live: ["x", "claude"], agents: ["x", "claude"], launched: ["claude"], preservingSelection: true)
        #expect(layout.groups.map(\.sessions) == [["x", "claude"]])
        #expect(layout.groups.map(\.selected) == ["x"])
        #expect(layout.lastAgent == "x")
        #expect(layout.focusedSession == "x")

        // A focused drawer terminal is followed into the tab it moves to.
        var focused = WorkspaceLayout<String>()
        focused.addAgent("x"); focused.addTerminal("claude"); focused.select("claude")
        focused.reconcile(live: ["x", "claude"], agents: ["x", "claude"], launched: ["claude"], preservingSelection: true)
        #expect(focused.groups.map(\.selected) == ["claude"])
        #expect(focused.focusedSession == "claude")
    }

}
