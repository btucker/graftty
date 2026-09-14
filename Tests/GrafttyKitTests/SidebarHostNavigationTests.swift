import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

struct SidebarHostNavigationTests {
    @Test("@spec LAYOUT-2.42: When a user reorders worktrees, the application shall preserve the main checkout first, stale entries last, and virtual-folder boundaries while moving only eligible siblings.")
    func worktreeMove() {
        let root = "/tmp/project"
        let main = WorktreeEntry(path: root, branch: "main", state: .closed)
        let a = WorktreeEntry(path: root + "/.worktrees/a", branch: "a", state: .closed)
        let b = WorktreeEntry(path: root + "/.worktrees/b", branch: "b", state: .closed)
        var state = AppState(repos: [RepoEntry(path: root, displayName: "project", worktrees: [main, a, b])])
        let moved = SidebarHostNavigation.moveWorktree(in: &state, repositoryID: root, worktreeID: b.path, relativeTo: a.path, after: false)
        #expect(moved)
        #expect(state.repos[0].worktrees.map(\.branch) == ["main", "b", "a"])
        let beforeMain = SidebarHostNavigation.moveWorktree(in: &state, repositoryID: root, worktreeID: b.path, relativeTo: main.path, after: false)
        #expect(!beforeMain)
        let stale = WorktreeEntry(path: root + "/gone", branch: "gone", state: .stale)
        let oldOrder = RepoEntry(path: root, displayName: "Project", worktrees: [stale, b, main, a])
        #expect(SidebarHostNavigation.canonicalWorktrees(in: oldOrder).map(\.branch) == ["main", "b", "a", "gone"])
    }

    @Test("Opening one occurrence preserves sibling requests and a newer request")
    func acknowledgeIsolation() {
        var wt = WorktreeEntry(path: "/project", branch: "main")
        let first = PaneSlotID(), second = PaneSlotID()
        let firstSession = wt.ensurePaneSession(for: first)
        _ = wt.ensurePaneSession(for: second)
        let old = Attention(text: "Review", timestamp: Date(timeIntervalSince1970: 1), source: .agentStop)
        let newer = Attention(text: "Review", timestamp: Date(timeIntervalSince1970: 2), source: .agentStop)
        wt.paneAttention[first] = newer
        wt.paneAttention[second] = old
        wt.attention = old
        var state = AppState(repos: [.init(path: "/project", displayName: "Project", worktrees: [wt])])
        let stale = SidebarHostNavigation.acknowledge(in: &state, worktreeID: wt.path, paneID: ZmxLauncher.sessionName(for: firstSession), occurrence: .init(timestamp: old.timestamp, text: old.text, source: old.source))
        #expect(!stale)
        let current = SidebarHostNavigation.acknowledge(in: &state, worktreeID: wt.path, paneID: ZmxLauncher.sessionName(for: firstSession), occurrence: .init(timestamp: newer.timestamp, text: newer.text, source: newer.source))
        #expect(current)
        #expect(state.repos[0].worktrees[0].paneAttention[first] == nil)
        #expect(state.repos[0].worktrees[0].paneAttention[second] == old)
        #expect(state.repos[0].worktrees[0].attention == old)
    }

    @Test("@spec PROJECT-3.1: When a project has no valid supported icon, the application shall fall back to stable initials without accepting malformed image data.")
    func invalidIcon() {
        #expect(ProjectIconDiscovery.thumbnail(Data("not an image".utf8)) == nil)
        let first = SidebarProject(id: "stable", repositoryID: "/old", name: "graftty-server")
        let second = SidebarProject(id: "stable", repositoryID: "/new", name: "graftty-server")
        #expect(first.displayInitials == "GS")
        #expect(first.colorIndex == second.colorIndex)
    }

    @Test("@spec PROJECT-3.2: When a project icon override or manual project order is saved, the application shall retain it across relaunches and decode older application state without those settings.")
    func persistence() throws {
        var repo = RepoEntry(path: "/project", displayName: "Project")
        repo.iconOverride = .initials("PR")
        var state = AppState(repos: [repo])
        state.sidebarNavigation = .init(order: .init(ids: ["a", "b"]))
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(AppState.self, from: data) == state)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "sidebarNavigation")
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(AppState.self, from: old).sidebarNavigation == nil)
    }
}
