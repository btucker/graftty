import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("Sidebar Team")
struct SidebarTeamTests {
    // Exercise the persisted format so these tests also cover migration.
    private func member(_ name: String, state: WorktreeState = .closed) throws -> WorktreeEntry {
        let entry = WorktreeEntry(path: "/repo/.worktrees/\(name)", branch: name, state: state)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json["isTeamMember"] = true
        return try JSONDecoder().decode(WorktreeEntry.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("@spec LAYOUT-2.102: When worktree state is saved and restored, the application shall preserve explicit Team membership and decode older worktrees as Tasks.")
    func membershipPersists() throws {
        let team = try member("architect")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(team)) as? [String: Any])
        #expect(json["isTeamMember"] as? Bool == true)

        let legacy = """
        {"id":"\(UUID())","path":"/repo/.worktrees/fix","branch":"fix","state":"closed","splitTree":{"root":null}}
        """
        let task = try JSONDecoder().decode(WorktreeEntry.self, from: Data(legacy.utf8))
        let taskJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        #expect(taskJSON["isTeamMember"] as? Bool == false)
    }

    @Test("@spec LAYOUT-2.106: When the user collapses a repository's Team section, the application shall preserve that disclosure state across relaunches and initially expand Team for older state.")
    func teamDisclosurePersists() throws {
        let repo = RepoEntry(path: "/repo", displayName: "repo")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(repo)) as? [String: Any])
        json["isTeamCollapsed"] = true
        let restored = try JSONDecoder().decode(RepoEntry.self, from: JSONSerialization.data(withJSONObject: json))
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        #expect(saved["isTeamCollapsed"] as? Bool == true)
        json.removeValue(forKey: "isTeamCollapsed")
        let legacy = try JSONDecoder().decode(RepoEntry.self, from: JSONSerialization.data(withJSONObject: json))
        let migrated = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(migrated["isTeamCollapsed"] as? Bool == false)
    }

    @Test("@spec LAYOUT-2.103: While the sidebar displays a repository, the application shall place its Tasks before its Team members, preserving manual Team order even when Tasks use recent activity order.")
    func teamFollowsTasksInStableOrder() throws {
        let main = WorktreeEntry(path: "/repo", branch: "main")
        var architect = try member("architect")
        var qa = try member("qa")
        var taskA = WorktreeEntry(path: "/repo/.worktrees/a", branch: "a")
        var taskB = WorktreeEntry(path: "/repo/.worktrees/b", branch: "b")
        architect.attention = Attention(text: "Review", timestamp: Date(timeIntervalSince1970: 400))
        qa.attention = Attention(text: "Test", timestamp: Date(timeIntervalSince1970: 500))
        taskA.attention = Attention(text: "A", timestamp: Date(timeIntervalSince1970: 100))
        taskB.attention = Attention(text: "B", timestamp: Date(timeIntervalSince1970: 200))
        var repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [architect, taskA, main, qa, taskB])
        #expect(SidebarHostNavigation.displayedWorktrees(in: repo).map(\.branch) == ["main", "a", "b", "architect", "qa"])
        repo.worktreeOrderMode = .recentActivity
        #expect(SidebarHostNavigation.displayedWorktrees(in: repo).map(\.branch) == ["main", "b", "a", "architect", "qa"])
        #expect(repo.worktrees.map(\.branch) == ["architect", "a", "main", "qa", "b"])
    }

    @Test("@spec LAYOUT-2.104: When a worktree is reordered in the sidebar, the application shall constrain the move to siblings within the same Tasks or Team section, allowing manual Team moves while Tasks use recent activity order.")
    func reordersStayWithinSections() throws {
        let teamA = try member("architect")
        let teamB = try member("qa")
        let task = WorktreeEntry(path: "/repo/.worktrees/fix", branch: "fix")
        var repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [teamA, task, teamB])
        var state = AppState(repos: [repo])
        #expect(!SidebarHostNavigation.moveWorktree(in: &state, repositoryID: repo.path,
            worktreeID: task.path, relativeTo: teamA.path, after: false))
        #expect(state.repos[0].worktrees == repo.worktrees)
        repo.worktreeOrderMode = .recentActivity
        state.repos = [repo]
        #expect(SidebarHostNavigation.moveWorktree(in: &state, repositoryID: repo.path,
            worktreeID: teamB.path, relativeTo: teamA.path, after: false))
        #expect(state.repos[0].worktrees.map(\.branch) == ["qa", "fix", "architect"])
    }

    @Test("@spec LAYOUT-2.105: If a Team worktree becomes stale, then the application shall retain its sidebar entry until the user explicitly dismisses it or removes its Team membership.")
    func staleTeamIsRetained() throws {
        var team = try member("architect", state: .stale)
        let now = Date(timeIntervalSince1970: 10_000)
        team.staleSince = now.addingTimeInterval(-7_200)
        let task = WorktreeEntry(path: "/repo/.worktrees/fix", branch: "fix", state: .stale, staleSince: team.staleSince)
        let state = AppState(repos: [RepoEntry(path: "/repo", displayName: "repo", worktrees: [team, task])])
        #expect(StaleWorktreeAutoDismissPolicy.expiredWorktreeIDs(in: state, now: now) == [task.id])
    }

    @Test("@spec LAYOUT-2.107: When the user adds or removes an eligible worktree from Team, the application shall change only its explicit membership, preserving its identity, panes, and instructions and excluding the main checkout and in-flight worktrees.")
    func membershipChangesPreserveWorkspace() throws {
        let main = WorktreeEntry(path: "/repo", branch: "main")
        var task = WorktreeEntry(path: "/repo/.worktrees/fix", branch: "fix", state: .running,
            splitTree: SplitTree(root: .leaf(PaneSlotID())))
        _ = task.ensurePaneSession(for: task.splitTree.allLeaves[0])
        let creating = WorktreeEntry(path: "/repo/.worktrees/new", branch: "new", state: .creating)
        var repos = [RepoEntry(path: "/repo", displayName: "repo", worktrees: [main, task, creating])]
        #expect(!SidebarHostNavigation.setTeamMembership(true, worktreeID: main.id, in: &repos))
        #expect(!SidebarHostNavigation.setTeamMembership(true, worktreeID: creating.id, in: &repos))
        #expect(SidebarHostNavigation.setTeamMembership(true, worktreeID: task.id, in: &repos))
        var expected = task
        expected.isTeamMember = true
        #expect(repos[0].worktrees[1] == expected)
        repos[0].worktrees[1].prepareForStop()
        #expect(repos[0].worktrees[1].isTeamMember)
        let saved = try JSONEncoder().encode(AppState(repos: repos))
        repos = try JSONDecoder().decode(AppState.self, from: saved).repos
        #expect(SidebarHostNavigation.setTeamMembership(false, worktreeID: task.id, in: &repos))
        #expect(repos[0].worktrees[1].path == task.path)
        #expect(repos[0].worktrees[1].splitTree == task.splitTree)
        #expect(!repos[0].worktrees[1].isTeamMember)
    }

    @Test func reconciliationPreservesTeamOrderAndMembership() throws {
        let architect = try member("architect")
        let qa = try member("qa")
        let result = WorktreeReconciler.reconcile(existing: [architect, qa], discovered: [
            DiscoveredWorktree(path: qa.path, branch: "new-qa-branch")
        ])
        #expect(result.merged.map(\.id) == [architect.id, qa.id])
        #expect(result.merged.allSatisfy { $0.isTeamMember })
        #expect(result.merged[0].state == .stale)
        #expect(result.merged[1].branch == "new-qa-branch")
    }

    @Test("@spec LAYOUT-2.108: When a host publishes sidebar metadata, the application shall include explicit Team membership for remote clients while accepting older metadata without it.")
    func remoteMetadataPreservesMembership() throws {
        let team = try member("architect")
        let metadata = SidebarHostNavigation.metadata(for: team, projectID: "project", folders: [])
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        #expect(json["isTeamMember"] as? Bool == true)
        var remoteJSON = json
        remoteJSON["isTeamMember"] = true
        let decoded = try JSONDecoder().decode(SidebarWorktreeMetadata.self,
            from: JSONSerialization.data(withJSONObject: remoteJSON))
        let roundTrip = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(roundTrip["isTeamMember"] as? Bool == true)
        let old = try JSONDecoder().decode(SidebarWorktreeMetadata.self, from: Data(#"{"id":"wt","projectID":"p","folders":[]}"#.utf8))
        #expect(old.id == "wt")
        #expect(old.isTeamMember == nil)
    }

    @Test func publishedFoldersStayWithinSections() throws {
        let team = try member("research/architect")
        let task = WorktreeEntry(path: "/repo/.worktrees/research/fix", branch: "research/fix")
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [team, task])
        // Each section has one worktree, so neither should acquire a folder
        // merely because its sibling in the other section shares a prefix.
        #expect(SidebarHostNavigation.folderAncestry(in: repo).values.allSatisfy { $0.isEmpty })
    }
}
