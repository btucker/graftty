import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyRemoteClient

@Suite("@spec REMOTE-13.37: While a paired host has saved wake addresses, the client shall keep its last reported projects and worktrees across launches, and shall delete them when the host is forgotten.")
struct HostSnapshotCacheTests {
    private func cache() throws -> HostSnapshotCache {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return HostSnapshotCache(directory: directory)
    }
    private let host = RemoteDeviceID(value: "mini")
    private var row: WorktreePanes {
        WorktreePanes(path: "/mini/w", displayName: "w", repoDisplayName: "app", displayBranch: "w", state: .running,
                      isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil)
    }

    @Test func cacheRoundTrips() throws {
        let cache = try cache()
        let project = SidebarProject(id: "p", repositoryID: "/r", name: "app", originKey: "k/app")
        try cache.save(hostID: host, projects: [project], rows: [row])
        let loaded = try #require(cache.load(hostID: host))
        #expect(loaded.projects == [project])
        #expect(loaded.rows == [row])
    }
    @Test func missingOrCorruptIsNil() throws {
        let cache = try cache()
        #expect(cache.load(hostID: host) == nil)
        try cache.save(hostID: host, projects: [], rows: [row])
        try Data("not json".utf8).write(to: cache.url(for: host))
        #expect(cache.load(hostID: host) == nil)
    }
    @Test func forgetRemovesCache() throws {
        let cache = try cache()
        try cache.save(hostID: host, projects: [], rows: [row])
        cache.remove(hostID: host)
        #expect(cache.load(hostID: host) == nil)
    }
    @Test func hostIDCannotEscapeDirectory() throws {
        let cache = try cache()
        let hostile = RemoteDeviceID(value: "../../evil")
        #expect(cache.url(for: hostile).deletingLastPathComponent().standardizedFileURL.path == cache.directory.standardizedFileURL.path)
    }
}
