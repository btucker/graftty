import Foundation
import SwiftUI
import Testing
import GrafttyKit
@testable import Graftty

@MainActor
private final class RelocationState {
    var state: AppState
    init(_ repos: [RepoEntry]) { state = AppState(repos: repos) }
    var binding: Binding<AppState> { Binding(get: { self.state }, set: { self.state = $0 }) }
}

@MainActor
private final class RelocationFixture {
    let root: URL
    let monitor = WorktreeMonitor()
    let stats = WorktreeStatsStore()
    let prs = PRStatusStore()
    let branches = RemoteBranchStore()

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relocation-reentrancy-\(UUID())")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true)
        root = URL(fileURLWithPath: CanonicalPath.canonicalize(directory.path))
    }

    func cleanUp() {
        monitor.stopAll()
        try? FileManager.default.removeItem(at: root)
    }

    func relocate(_ box: RelocationState,
                  discover: @MainActor (RepoEntry) async throws -> [DiscoveredWorktree],
                  repair: @MainActor (String, [String]) async throws -> Void = { _, _ in }) async {
        await GrafttyApp.relocateRepo(
            appState: box.binding, worktreeMonitor: monitor, statsStore: stats,
            prStatusStore: prs, remoteBranchStore: branches, repoIdx: 0,
            newURL: root, isStale: false, discover: discover, repair: repair
        )
    }
}

@Suite("@spec LAYOUT-4.11: When repository discovery or repair suspends during relocation, the application shall apply the result only to the same repository identity at the expected path, preserving other repositories and skipping a removed repository.")
@MainActor
struct RepoRelocationReentrancyTests {
    @Test(arguments: ["discovery", "repair", "rediscovery"])
    func reorderDuringSuspension(_ stage: String) async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let target = RepoEntry(path: "/old", displayName: "target", worktrees: [WorktreeEntry(path: "/old", branch: "main")])
        let other = RepoEntry(path: "/other", displayName: "other", worktrees: [WorktreeEntry(path: "/other", branch: "other")])
        let box = RelocationState([target, other])
        var calls = 0
        await fixture.relocate(box, discover: { repo in
            calls += 1
            if stage == "discovery" || (stage == "rediscovery" && calls == 2) {
                await Task.yield()
                box.state.repos.swapAt(0, 1)
            }
            if stage != "discovery" && calls == 1 { return [] }
            #expect(repo.id == target.id, "rediscovery must read the relocated repository")
            return [DiscoveredWorktree(path: fixture.root.path, branch: "main")]
        }, repair: { _, _ in
            if stage == "repair" {
                await Task.yield()
                box.state.repos.swapAt(0, 1)
            }
        })
        #expect(box.state.repos.first(where: { $0.id == other.id }) == other)
        #expect(box.state.repos.first(where: { $0.id == target.id })?.worktrees.first?.path == fixture.root.path)
    }

    @Test(arguments: ["discovery", "repair", "rediscovery"], [false, true])
    func invalidatedRepositoryIsNotReplacedByItsResult(_ stage: String, movedAgain: Bool) async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let target = RepoEntry(path: "/old", displayName: "target", worktrees: [WorktreeEntry(path: "/old", branch: "main")])
        var replacement = movedAgain ? target : RepoEntry(path: fixture.root.path, displayName: "replacement")
        if movedAgain { replacement.path = "/newer-location" }
        let box = RelocationState([target])
        var calls = 0
        await fixture.relocate(box, discover: { _ in
            calls += 1
            if stage == "discovery" || (stage == "rediscovery" && calls == 2) {
                await Task.yield()
                box.state.repos = [replacement]
                box.state.selectedWorktreePath = "/replacement-selection"
            }
            return calls == 1 && stage != "discovery" ? [] : [DiscoveredWorktree(path: fixture.root.path, branch: "main")]
        }, repair: { _, _ in
            if stage == "repair" {
                await Task.yield()
                box.state.repos = [replacement]
            }
        })
        #expect(box.state.repos == [replacement])
        if stage != "repair" { #expect(box.state.selectedWorktreePath == "/replacement-selection") }
        if stage == "repair" { #expect(calls == 1, "removed repositories must not be rediscovered") }
    }

    @Test func removingTheLastRepositoryDuringDiscoveryIsSafe() async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target")])
        await fixture.relocate(box, discover: { _ in
            await Task.yield()
            box.state.repos.removeAll()
            return []
        })
        #expect(box.state.repos.isEmpty)
    }

}

@Suite("@spec LAYOUT-4.12: When a repository is removed while launch-time location resolution suspends, the application shall continue resolving the remaining original repository identities without using stale array offsets.")
@MainActor
struct RepoLocationResolutionReentrancyTests {
    @Test func launchResolutionSurvivesReorderingAndRemoval() async throws {
        let first = try RelocationFixture()
        let second = try RelocationFixture()
        defer { first.cleanUp(); second.cleanUp() }
        let a = RepoEntry(path: "/old-a", displayName: "a", bookmark: try RepoBookmark.mint(atPath: first.root.path))
        let b = RepoEntry(path: "/old-b", displayName: "b", bookmark: try RepoBookmark.mint(atPath: second.root.path))
        let decoy = RepoEntry(path: "/decoy", displayName: "decoy")
        let box = RelocationState([a, b])
        var discoveredIDs: [UUID] = []
        await GrafttyApp.resolveRepoLocations(
            appState: box.binding, worktreeMonitor: first.monitor, statsStore: first.stats,
            prStatusStore: first.prs, remoteBranchStore: first.branches,
            discover: { repo in
                discoveredIDs.append(repo.id)
                if repo.id == a.id {
                    await Task.yield()
                    box.state.repos = [b, decoy]
                }
                return []
            }
        )
        #expect(discoveredIDs == [a.id, b.id])
        #expect(box.state.repos.first?.path == second.root.path)
        #expect(box.state.repos.last == decoy)
    }
}
