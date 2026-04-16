import Testing
import Foundation
@testable import EspalierKit

@Suite("AppState Tests")
struct AppStateTests {

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("espalier-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func emptyStateHasNoRepos() {
        let state = AppState()
        #expect(state.repos.isEmpty)
        #expect(state.selectedWorktreePath == nil)
    }

    @Test func addRepo() {
        var state = AppState()
        let repo = RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main")
        ])
        state.addRepo(repo)
        #expect(state.repos.count == 1)
    }

    @Test func addDuplicateRepoIsIgnored() {
        var state = AppState()
        let repo1 = RepoEntry(path: "/tmp/repo", displayName: "repo")
        let repo2 = RepoEntry(path: "/tmp/repo", displayName: "repo-dup")
        state.addRepo(repo1)
        state.addRepo(repo2)
        #expect(state.repos.count == 1)
    }

    @Test func removeRepo() {
        var state = AppState()
        let repo = RepoEntry(path: "/tmp/repo", displayName: "repo")
        state.addRepo(repo)
        state.removeRepo(atPath: "/tmp/repo")
        #expect(state.repos.isEmpty)
    }

    @Test func saveAndLoad() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var state = AppState()
        state.addRepo(RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main")
        ]))
        state.selectedWorktreePath = "/tmp/repo"
        state.sidebarWidth = 280

        try state.save(to: dir)

        let loaded = try AppState.load(from: dir)
        #expect(loaded.repos.count == 1)
        #expect(loaded.repos[0].path == "/tmp/repo")
        #expect(loaded.selectedWorktreePath == "/tmp/repo")
        #expect(loaded.sidebarWidth == 280)
    }

    @Test func loadFromEmptyDirReturnsDefault() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let loaded = try AppState.load(from: dir)
        #expect(loaded.repos.isEmpty)
    }

    @Test func worktreeForPathFindsCorrectEntry() {
        var state = AppState()
        let wt = WorktreeEntry(path: "/tmp/worktrees/feature", branch: "feature/x")
        state.addRepo(RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main"),
            wt,
        ]))
        let found = state.worktree(forPath: "/tmp/worktrees/feature")
        #expect(found?.branch == "feature/x")
    }

    @Test func worktreeForPathReturnsNilWhenNotFound() {
        let state = AppState()
        #expect(state.worktree(forPath: "/nonexistent") == nil)
    }

    @Test func windowFrameCustomValuesSurviveSaveAndLoad() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var state = AppState()
        state.windowFrame = WindowFrame(x: 500, y: 200, width: 1600, height: 1000)

        try state.save(to: dir)
        let loaded = try AppState.load(from: dir)

        #expect(loaded.windowFrame.x == 500)
        #expect(loaded.windowFrame.y == 200)
        #expect(loaded.windowFrame.width == 1600)
        #expect(loaded.windowFrame.height == 1000)
    }

    @Test func sidebarWidthCustomValueSurvivesSaveAndLoad() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var state = AppState()
        state.sidebarWidth = 312.5

        try state.save(to: dir)
        let loaded = try AppState.load(from: dir)

        #expect(loaded.sidebarWidth == 312.5)
    }

    @Test func windowFrameEquatableDistinguishesByValue() {
        let a = WindowFrame(x: 0, y: 0, width: 800, height: 600)
        let b = WindowFrame(x: 0, y: 0, width: 800, height: 600)
        let c = WindowFrame(x: 1, y: 0, width: 800, height: 600)
        #expect(a == b)
        #expect(a != c)
    }

    /// Mirrors the CLI's `WorktreeResolver.isTracked` flow: the CLI loads
    /// the on-disk state.json and checks whether a PWD-derived path
    /// corresponds to a tracked worktree. This test exercises the same
    /// load → `worktree(forPath:)` pipeline to catch regressions that
    /// would make `espalier notify` silently accept or reject paths.
    @Test func cliTrackingCheckRoundTripsThroughStateJSON() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var state = AppState()
        state.addRepo(RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main"),
            WorktreeEntry(path: "/tmp/worktrees/feature", branch: "feature"),
        ]))
        try state.save(to: dir)

        let loaded = try AppState.load(from: dir)

        // Tracked paths are recognized.
        #expect(loaded.worktree(forPath: "/tmp/repo") != nil)
        #expect(loaded.worktree(forPath: "/tmp/worktrees/feature") != nil)

        // Untracked paths — including the worktrees' parent and a random
        // directory — are rejected.
        #expect(loaded.worktree(forPath: "/tmp/worktrees") == nil)
        #expect(loaded.worktree(forPath: "/Users/elsewhere") == nil)
    }

    /// When state.json is missing entirely (fresh install), the CLI's
    /// tracking check must fail closed — nothing is tracked, so every
    /// `notify` correctly errors out rather than silently no-op'ing against
    /// an empty in-memory state.
    @Test func cliTrackingCheckReturnsNilForMissingStateJSON() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No save. `load` returns a default AppState with no repos.

        let loaded = try AppState.load(from: dir)
        #expect(loaded.repos.isEmpty)
        #expect(loaded.worktree(forPath: "/tmp/repo") == nil)
    }
}
