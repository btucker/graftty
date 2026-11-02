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

    /// Hold the real orchestrator open while a separate main-actor task edits its model.
    func relocate(_ box: RelocationState, suspendedAt stage: String,
                  discovered: [DiscoveredWorktree], whileSuspended edit: () -> Void) async {
        let (arrivals, arrival) = AsyncStream<Void>.makeStream()
        var gate: CheckedContinuation<Void, Never>?
        var calls = 0
        let task = Task {
            await relocate(box, discover: { _ in
                calls += 1
                if (stage == "discovery" && calls == 1) || (stage == "rediscovery" && calls == 2) {
                    await withCheckedContinuation { gate = $0; arrival.yield(()) }
                }
                return calls == 1 && stage != "discovery" ? [] : discovered
            }, repair: { _, _ in
                if stage == "repair" {
                    await withCheckedContinuation { gate = $0; arrival.yield(()) }
                }
            })
        }
        var events = arrivals.makeAsyncIterator()
        _ = await events.next()
        edit()
        gate?.resume()
        await task.value
        arrival.finish()
    }
}

@Suite("@spec LAYOUT-4.13: When discovery or repair suspends during repository relocation, the application shall merge relocation decisions by worktree identity into current rows, preserving concurrent layout, state, order, additions, and removals without duplicate discoveries.")
@MainActor
struct RepoRelocationWorktreeMergeTests {
    @Test(arguments: ["discovery", "repair", "rediscovery"])
    func concurrentWorktreeEditsSurvive(_ stage: String) async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let main = WorktreeEntry(path: "/old", branch: "main")
        let removed = WorktreeEntry(path: "/old/removed", branch: "removed")
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: [main, removed])])
        let added = WorktreeEntry(path: fixture.root.path + "/added", branch: "added", state: .running)
        let local = WorktreeEntry(path: fixture.root.path + "/local", branch: "local")
        // Concurrent creation can adopt the moved main checkout as a sibling
        // before relocation has rewritten the original row's old path.
        let adoptedMain = WorktreeEntry(path: fixture.root.path, branch: "main")
        var edited = main
        let first = PaneSlotID()
        let second = PaneSlotID()
        edited.splitTree = SplitTree(root: .leaf(first)).inserting(second, at: first, direction: .horizontal)
        edited.focusedPaneSlotID = second
        edited.primaryPaneSlotID = first
        edited.state = .running
        edited.isPinned = true
        edited.attention = Attention(text: "new attention", timestamp: Date(timeIntervalSince1970: 123))
        edited.paneAttention[second] = edited.attention
        let discoveries = [
            DiscoveredWorktree(path: fixture.root.path, branch: "main"),
            DiscoveredWorktree(path: fixture.root.path + "/removed", branch: "removed"),
            DiscoveredWorktree(path: added.path, branch: added.branch),
            DiscoveredWorktree(path: fixture.root.path + "/fresh", branch: "fresh")
        ]
        await fixture.relocate(box, suspendedAt: stage, discovered: discoveries) {
            box.state.repos[0].worktrees = [added, adoptedMain, edited, local]
        }
        edited.path = fixture.root.path
        let actual = box.state.repos[0].worktrees
        #expect(Array(actual.prefix(3)) == [added, edited, local])
        #expect(actual.count == 4)
        #expect(actual.last?.branch == "fresh")
        #expect(!actual.contains { $0.id == removed.id || $0.branch == removed.branch })
        #expect(actual.filter { $0.path == added.path }.count == 1)
        #expect(actual.filter { $0.path == edited.path }.map(\.id) == [edited.id])
    }

    @Test(arguments: ["discovery", "repair", "rediscovery"])
    func staleRowsKeepConcurrentEditsAndRemovedStaleRowsStayRemoved(_ stage: String) async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let missing = WorktreeEntry(path: "/old/missing", branch: "missing")
        let removed = WorktreeEntry(path: "/old/removed", branch: "removed")
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: [missing, removed])])
        var edited = missing
        edited.isPinned = true
        edited.emoji = "🐝"
        edited.markStale(at: Date(timeIntervalSince1970: 123))
        await fixture.relocate(box, suspendedAt: stage, discovered: []) {
            box.state.repos[0].worktrees = [edited]
        }
        #expect(box.state.repos[0].worktrees == [edited])
    }

    @Test(arguments: ["discovery", "repair", "rediscovery"])
    func removedIdentityDestinationCanBeReplaced(_ stage: String) async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let original = WorktreeEntry(path: "/old", branch: "main")
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: [original])])
        var replacement = WorktreeEntry(path: fixture.root.path, branch: "main", state: .running)
        replacement.splitTree = SplitTree(root: .leaf(PaneSlotID()))
        box.state.selectedWorktreePath = original.path
        await fixture.relocate(box, suspendedAt: stage, discovered: [
            DiscoveredWorktree(path: fixture.root.path, branch: "main")
        ]) {
            box.state.repos[0].worktrees = [replacement]
            box.state.selectedWorktreePath = replacement.path
        }
        #expect(box.state.repos[0].worktrees == [replacement])
        #expect(box.state.selectedWorktreePath == replacement.path)
    }
}

@Suite("@spec LAYOUT-4.14: When selection changes while repository relocation is suspended, the application shall resolve the latest selection by current worktree identity, relocate a selected surviving worktree, clear a selected stale worktree, and preserve a selected replacement, selection outside the relocation, or an explicit deselection.")
@MainActor
struct RepoRelocationSelectionMergeTests {
    @Test(arguments: ["discovery", "repair", "rediscovery"])
    func selectionBelongsToReplacementAtReusedPath(_ stage: String) async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let original = WorktreeEntry(path: "/external", branch: "old-branch")
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: [original])])
        let replacement = WorktreeEntry(path: original.path, branch: "new-branch")
        await fixture.relocate(box, suspendedAt: stage, discovered: [
            DiscoveredWorktree(path: replacement.path, branch: replacement.branch)
        ]) {
            box.state.repos[0].worktrees = [replacement]
            box.state.selectedWorktreePath = replacement.path
        }
        #expect(box.state.repos[0].worktrees == [replacement])
        #expect(box.state.selectedWorktreePath == replacement.path)
    }

    @Test(arguments: ["discovery", "repair", "rediscovery"], ["surviving", "stale", "outside", "none"])
    func latestSelectionSurvives(_ stage: String, selection: String) async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let worktrees = [WorktreeEntry(path: "/old", branch: "main"),
                         WorktreeEntry(path: "/old/linked", branch: "linked"),
                         WorktreeEntry(path: "/old/stale", branch: "stale")]
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: worktrees)])
        box.state.selectedWorktreePath = "/old"
        let latest: String?
        let expected: String?
        switch selection {
        case "surviving": latest = "/old/linked"; expected = fixture.root.path + "/linked"
        case "stale": latest = "/old/stale"; expected = nil
        case "outside": latest = "/other"; expected = latest
        default: latest = nil; expected = nil
        }
        await fixture.relocate(box, suspendedAt: stage, discovered: [
            DiscoveredWorktree(path: fixture.root.path, branch: "main"),
            DiscoveredWorktree(path: fixture.root.path + "/linked", branch: "linked")
        ]) {
            box.state.selectedWorktreePath = latest
        }
        #expect(box.state.selectedWorktreePath == expected)
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
