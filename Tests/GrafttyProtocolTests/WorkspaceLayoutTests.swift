import Foundation
import Testing
@testable import GrafttyProtocol

struct WorkspaceLayoutTests {
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

}
