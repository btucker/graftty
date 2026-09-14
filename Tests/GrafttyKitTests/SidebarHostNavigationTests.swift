import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol
import Darwin

struct SidebarHostNavigationTests {
    @Test("@spec REMOTE-14.6: When folder metadata is published, the application shall retain native virtual-folder labels and identities, including separate folders with the same display name.")
    func folderMetadataPreservesNativeHierarchy() throws {
        let root = "/projects/repo"
        let managed = ["a", "b"].map { WorktreeEntry(path: root + "/.worktrees/worktrees/" + $0, branch: $0) }
        let external = ["c", "d"].map { WorktreeEntry(path: "/tmp/external/worktrees/" + $0, branch: $0) }
        let nodes = SidebarWorktreeHierarchy.nodes(for: managed + external, inRepoAtPath: root, defaultBranch: nil)
        let ancestry = SidebarWorktreeHierarchy.folderAncestry(in: nodes)
        let first = try #require(ancestry[managed[0].id])
        let second = try #require(ancestry[external[0].id])
        #expect(first.map(\.name) == ["worktrees"])
        #expect(second.map(\.name) == ["worktrees"])
        #expect(first.map(\.id) != second.map(\.id))
        let rows = (managed + external).map { worktree in
            let folders = ancestry[worktree.id] ?? []
            return WorktreePanes(path: worktree.path, displayName: worktree.branch, repoDisplayName: "Project", displayBranch: worktree.branch, state: .closed, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
                sidebar: SidebarHostNavigation.metadata(for: worktree, projectID: "p", folders: folders.map(\.name), folderIDs: folders.map(\.id)))
        }
        let projected = SidebarWorktreeTree.nodes(rows)
        #expect(projected.map(\.name) == ["worktrees", "worktrees"])
        #expect(Set(projected.map(\.id)).count == 2)
        #expect(projected[0].children?.compactMap { $0.worktree?.path } == managed.map(\.path))
        #expect(projected[1].children?.compactMap { $0.worktree?.path } == external.map(\.path))
    }

    @Test("@spec PROJECT-3.3: When an icon file is read, the application shall reject nonregular files and read no more than the supported image byte limit.")
    func boundedRegularIconRead() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let regular = directory.appendingPathComponent("icon.png")
        let bytes = Data("small regular file".utf8)
        try bytes.write(to: regular)
        #expect(ProjectIconDiscovery.readImageData(at: regular) == bytes)
        let link = directory.appendingPathComponent("favicon.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        #expect(ProjectIconDiscovery.readImageData(at: link) == nil)
        let fifo = directory.appendingPathComponent("favicon.ico")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(ProjectIconDiscovery.readImageData(at: fifo) == nil)
        #expect(ProjectIconDiscovery.readImageData(at: directory) == nil)
        try Data(repeating: 0, count: 2 * 1024 * 1024 + 1).write(to: regular)
        #expect(ProjectIconDiscovery.readImageData(at: regular) == nil)
        #expect(ProjectIconDiscovery.discover(at: directory) == nil)
    }

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
