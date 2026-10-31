import Foundation
import Testing
@testable import GrafttyProtocol

struct WorkspaceLayoutTests {
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
}
