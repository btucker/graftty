import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

@Suite("@spec LAYOUT-2.203: When a host loads repositories and pinned worktrees without ranks, the application shall assign ranks from their current order without a change time and keep existing ranks.")
struct SidebarRankSeedingTests {
    private func repos() -> [RepoEntry] {
        var one = WorktreeEntry(path: "/one/a", branch: "a"); one.isPinned = true
        var two = WorktreeEntry(path: "/one/b", branch: "b"); two.isPinned = true
        return [RepoEntry(path: "/one", displayName: "one", worktrees: [WorktreeEntry(path: "/one", branch: "main"), one, two]),
                RepoEntry(path: "/two", displayName: "two", worktrees: [WorktreeEntry(path: "/two", branch: "main")])]
    }

    @Test func seedRanksFollowCurrentOrderWithoutTime() {
        var repos = repos()
        SidebarHostNavigation.seedRanks(in: &repos, projectOrder: [repos[1].id, repos[0].id])
        #expect(repos[1].projectRank! < repos[0].projectRank!)
        #expect(repos[0].projectRankChangedAt == nil)
        #expect(repos[0].worktrees[1].pinnedRank! < repos[0].worktrees[2].pinnedRank!)
        #expect(repos[0].worktrees[0].pinnedRank == nil)
    }
    @Test func seedKeepsExistingRanks() {
        var repos = repos()
        repos[0].projectRank = "z"
        repos[0].worktrees[1].pinnedRank = "m"
        SidebarHostNavigation.seedRanks(in: &repos, projectOrder: repos.map(\.id))
        #expect(repos[0].projectRank == "z")
        #expect(repos[0].worktrees[1].pinnedRank == "m")
        #expect(repos[0].worktrees[2].pinnedRank! > "m")
        #expect(repos[1].projectRank! > "z")
    }
    @Test func unpinningClearsRank() {
        var repos = repos()
        SidebarHostNavigation.seedRanks(in: &repos, projectOrder: repos.map(\.id))
        let id = repos[0].worktrees[1].id
        #expect(SidebarHostNavigation.setPinned(false, worktreeID: id, in: &repos))
        #expect(repos[0].worktrees[1].pinnedRank == nil)
    }
    @Test func setPinnedRankRejectsUnknownRow() {
        var state = AppState(repos: repos())
        #expect(!SidebarHostNavigation.setPinnedRank("a", worktreeID: "/nope", repositoryID: "/one", in: &state))
        #expect(!SidebarHostNavigation.setPinnedRank("a", worktreeID: "/two", repositoryID: "/two", in: &state))
        #expect(!SidebarHostNavigation.setPinnedRank("bad rank", worktreeID: "/one/a", repositoryID: "/one", in: &state))
        #expect(SidebarHostNavigation.setPinnedRank("a", worktreeID: "/one/a", repositoryID: "/one", in: &state))
        #expect(state.repos[0].worktrees[1].pinnedRank == "a")
    }
    @Test func setProjectRankKeepsNewestTime() {
        var state = AppState(repos: repos())
        #expect(SidebarHostNavigation.setProjectRank("b", changedAt: 20, repositoryID: "/one", in: &state))
        #expect(SidebarHostNavigation.setProjectRank("c", changedAt: 10, repositoryID: "/one", in: &state))
        #expect(state.repos[0].projectRank == "b")
        #expect(state.repos[0].projectRankChangedAt == 20)
        #expect(!SidebarHostNavigation.setProjectRank("c", changedAt: 30, repositoryID: "/nope", in: &state))
        #expect(!SidebarHostNavigation.setProjectRank("bad rank", changedAt: 30, repositoryID: "/one", in: &state))
    }
    @Test func pinnedOrderFollowsRankForOlderClients() {
        var state = AppState(repos: repos())
        #expect(SidebarHostNavigation.setPinnedRank("b", worktreeID: "/one/a", repositoryID: "/one", in: &state))
        #expect(SidebarHostNavigation.setPinnedRank("a", worktreeID: "/one/b", repositoryID: "/one", in: &state))
        #expect(SidebarHostNavigation.canonicalWorktrees(in: state.repos[0]).map(\.path) == ["/one", "/one/b", "/one/a"])
    }
    @Test func olderClientMoveUpdatesRank() {
        var state = AppState(repos: repos())
        SidebarHostNavigation.seedRanks(in: &state.repos, projectOrder: state.repos.map(\.id))
        #expect(SidebarHostNavigation.moveWorktree(in: &state, repositoryID: "/one", worktreeID: "/one/b", relativeTo: "/one/a", after: false))
        #expect(SidebarHostNavigation.canonicalWorktrees(in: state.repos[0]).map(\.path) == ["/one", "/one/b", "/one/a"])
        let moved = state.repos[0].worktrees.first { $0.path == "/one/b" }!
        let other = state.repos[0].worktrees.first { $0.path == "/one/a" }!
        #expect(moved.pinnedRank! < other.pinnedRank!)
    }
    @Test func metadataPublishesActivityAndRank() {
        var entry = WorktreeEntry(path: "/one/a", branch: "a", createdAt: Date(timeIntervalSinceReferenceDate: 50))
        entry.isPinned = true
        entry.pinnedRank = "m"
        let metadata = SidebarHostNavigation.metadata(for: entry, projectID: "p", folders: [])
        #expect(metadata.activityTime == 50)
        #expect(metadata.pinnedRank == "m")
    }
    @Test func olderStateJSONDecodes() throws {
        let repos = try JSONDecoder().decode([RepoEntry].self, from: Data(#"[{"id":"00000000-0000-0000-0000-000000000001","path":"/r","displayName":"r","worktrees":[]}]"#.utf8))
        #expect(repos[0].originKey == nil)
        #expect(repos[0].projectRank == nil)
    }
    @Test func newFieldsSurviveRestart() throws {
        var repos = repos()
        repos[0].originKey = "github.com/acme/app"
        repos[0].projectRank = "b"
        repos[0].projectRankChangedAt = 5
        repos[0].worktrees[1].pinnedRank = "c"
        let restored = try JSONDecoder().decode([RepoEntry].self, from: JSONEncoder().encode(repos))
        #expect(restored[0].originKey == "github.com/acme/app")
        #expect(restored[0].projectRank == "b")
        #expect(restored[0].projectRankChangedAt == 5)
        #expect(restored[0].worktrees[1].pinnedRank == "c")
    }
    @Test func applyOriginKeysKeepsKeyOnFailedLookup() {
        var repos = repos()
        SidebarHostNavigation.applyOriginKeys(["/one": "k/one"], in: &repos)
        #expect(repos[0].originKey == "k/one")
        SidebarHostNavigation.applyOriginKeys([:], in: &repos)
        #expect(repos[0].originKey == "k/one")
    }
}
