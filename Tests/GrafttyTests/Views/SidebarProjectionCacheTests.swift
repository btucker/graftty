import Foundation
import Testing
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI
@testable import Graftty

@MainActor
struct SidebarProjectionCacheTests {
    private let owner = SidebarProjectionFixture.owner

    @Test("@spec PERF-1.27: While local sidebar repository paths, worktree identities, paths, branches, pins, membership, order, and resolved default branches are unchanged, the application shall reuse folder ancestry and labels while projecting current row content and display order.")
    func liveUpdatesReuseMetadataAndMatchUncachedRows() throws {
        var state = SidebarProjectionFixture.state(repositories: 2, rows: 16)
        var builds = 0
        let cache = SidebarLocalWorktreeMetadataCache { repo, branch in
            builds += 1
            return SidebarLocalWorktreeMetadata(repo: repo, defaultBranch: branch)
        }
        let initial = sidebarLocalWorktrees(state: state, owner: owner, titles: [:], liveness: [:], metadataCache: cache)
        let path = state.repos[0].worktrees[3].path
        let slot = try #require(state.repos[0].worktrees[3].splitTree.allLeaves.first)
        let session = PaneSessionID()
        let badge = PRBadge(number: 17, state: .open, checks: .success, url: URL(string: "https://example.com/pull/17")!)
        for update in 1...4 {
            state.repos[0].displayName = "Renamed \(update)"
            state.selectedWorktreePath = path
            state.repos[0].worktrees[3].state = update % 2 == 0 ? .closed : .running
            state.repos[0].worktrees[3].attention = .init(text: "Attention \(update)", timestamp: Date(timeIntervalSinceReferenceDate: 100 + Double(update)))
            state.repos[0].worktrees[3].unseenAgentStop = .init(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: Double(update)),
                recap: .init(title: "Report \(update)", completed: "Changed", next: "Review"))
            state.repos[0].worktrees[3].emoji = "🌳"
            state.repos[0].worktrees[3].paneSessions[slot] = session
            let addedSlot = PaneSlotID()
            state.repos[0].worktrees[3].splitTree = .init(root: .split(.init(
                direction: .horizontal, ratio: 0.5, left: .leaf(slot), right: .leaf(addedSlot))))
            state.repos[0].worktrees[3].paneAttention[slot] = .init(text: "Pane \(update)", timestamp: Date(timeIntervalSinceReferenceDate: Double(update)))
            state.repos[0].worktrees[1].pinnedRank = "z"
            state.repos[0].worktrees[2].pinnedRank = "a"
            let titles = [slot: "Title \(update)"]
            let liveness: [String: AgentLiveness] = [ZmxLauncher.sessionName(for: session): update % 2 == 0 ? .idle : .busy]
            let rows = sidebarLocalWorktrees(state: state, owner: owner, titles: titles, liveness: liveness,
                                             prBadges: [path: badge], metadataCache: cache)
            #expect(rows == sidebarLocalWorktrees(state: state, owner: owner, titles: titles, liveness: liveness, prBadges: [path: badge]))
            #expect(rows != initial)
            #expect(rows.first { $0.path == path }?.layout?.leaves.first?.title == "Title \(update)")
            #expect(rows.map(\.path) == state.repos.flatMap { SidebarHostNavigation.displayedWorktrees(in: $0).map(\.path) })
        }
        #expect(builds == 2)
    }

    enum Mutation: CaseIterable {
        case worktreePath, repositoryPath, pin, addSibling, removeSibling, replaceIdentity, order, resolvedBranch, fallbackBranch, moveRepository
    }

    @Test("@spec PERF-1.28: When local sidebar metadata inputs change or a repository is removed, the application shall invalidate the affected cached metadata and preserve the uncached projection's labels, folders, identities, membership, and ordering.", arguments: Mutation.allCases)
    func structuralChangesMatchUncachedProjection(_ mutation: Mutation) {
        var state = SidebarProjectionFixture.state(repositories: 2, rows: 16)
        // Empty paths exercise the label's branch fallback as well as managed and external paths.
        state.repos[0].worktrees.append(WorktreeEntry(path: "", branch: "fallback"))
        var builtRepositories: [UUID] = []
        let cache = SidebarLocalWorktreeMetadataCache { repo, branch in
            builtRepositories.append(repo.id)
            return SidebarLocalWorktreeMetadata(repo: repo, defaultBranch: branch)
        }
        var branch: String? = "trunk"
        func project(_ cache: SidebarLocalWorktreeMetadataCache?) -> [WorktreePanes] {
            sidebarLocalWorktrees(state: state, owner: owner, titles: [:], liveness: [:],
                                 metadataCache: cache, defaultBranch: { _ in branch })
        }
        let initial = project(cache)
        #expect(project(cache) == initial)
        #expect(builtRepositories.count == 2)
        builtRepositories.removeAll()
        switch mutation {
        case .worktreePath: state.repos[0].worktrees[3].path = "/synthetic/relocated/checkout"
        case .repositoryPath:
            let old = state.repos[0].path
            state.repos[0].path = "/synthetic/moved/repository"
            for index in state.repos[0].worktrees.indices where state.repos[0].worktrees[index].path.hasPrefix(old) {
                state.repos[0].worktrees[index].path = state.repos[0].worktrees[index].path.replacingOccurrences(of: old, with: state.repos[0].path)
            }
        case .pin: state.repos[0].worktrees[1].isPinned = false
        case .addSibling: state.repos[0].worktrees.append(WorktreeEntry(path: "/synthetic/another/checkout", branch: "another"))
        case .removeSibling: state.repos[0].worktrees.remove(at: 1)
        case .replaceIdentity:
            let old = state.repos[0].worktrees[3]
            state.repos[0].worktrees[3] = WorktreeEntry(path: old.path, branch: old.branch)
        case .order: state.repos[0].worktrees.reverse()
        case .resolvedBranch: branch = "resolved-default"
        case .fallbackBranch: state.repos[0].worktrees[state.repos[0].worktrees.count - 1].branch = "new-fallback"
        case .moveRepository: state.repos[1].worktrees.append(state.repos[0].worktrees.remove(at: 3))
        }
        let actual = project(cache)
        #expect(actual == project(nil))
        let expectedBuilds = mutation == .resolvedBranch || mutation == .moveRepository ? 2 : 1
        #expect(builtRepositories.count == expectedBuilds)
        #expect(project(cache) == actual)
        #expect(builtRepositories.count == expectedBuilds)
    }

    @Test func removedRepositoriesAreEvictedAndOwnerRemainsLive() {
        var state = SidebarProjectionFixture.state(repositories: 2, rows: 8)
        var builds = 0
        let cache = SidebarLocalWorktreeMetadataCache { repo, branch in
            builds += 1
            return SidebarLocalWorktreeMetadata(repo: repo, defaultBranch: branch)
        }
        _ = sidebarLocalWorktrees(state: state, owner: owner, titles: [:], liveness: [:], metadataCache: cache)
        let removed = state.repos.removeFirst()
        _ = sidebarLocalWorktrees(state: state, owner: owner, titles: [:], liveness: [:], metadataCache: cache)
        state.repos.append(removed)
        let newOwner = WorktreeOrigin(deviceID: .init(value: "replacement"), deviceLabel: "New", relayDepth: 0)
        let rows = sidebarLocalWorktrees(state: state, owner: newOwner, titles: [:], liveness: [:], metadataCache: cache)
        #expect(rows == sidebarLocalWorktrees(state: state, owner: newOwner, titles: [:], liveness: [:]))
        #expect(builds == 3)
    }

    @Test func currentReportsAndSelectionSurviveNavigationRefresh() throws {
        var state = SidebarProjectionFixture.state(repositories: 1, rows: 8)
        let cache = SidebarLocalWorktreeMetadataCache()
        let suite = "projection-navigation-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cachedNavigation = SidebarNavigationState(prefix: "cached", defaults: defaults)
        let uncachedNavigation = SidebarNavigationState(prefix: "uncached", defaults: defaults)
        let project = SidebarProject(id: "\(owner.deviceID.value):\(state.repos[0].id.uuidString)",
                                     repositoryID: state.repos[0].path, name: "Synthetic", owner: owner)
        cachedNavigation.selectedProjectID = project.id
        uncachedNavigation.selectedProjectID = project.id
        let slot = try #require(state.repos[0].worktrees[3].splitTree.allLeaves.first)
        let session = try #require(state.repos[0].worktrees[3].paneSessions[slot])
        for update in 0..<3 {
            state.repos[0].worktrees[3].unseenAgentStop = update == 1 ? nil : .init(
                agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: Double(update)),
                recap: .init(title: "Report \(update)", completed: "Done", next: "Review", need: "Approve?"))
            let titles = [slot: "Current \(update)"]
            let liveness: [String: AgentLiveness] = [ZmxLauncher.sessionName(for: session): update == 1 ? .busy : .idle]
            let cached = sidebarLocalWorktrees(state: state, owner: owner, titles: titles, liveness: liveness, metadataCache: cache)
            let uncached = sidebarLocalWorktrees(state: state, owner: owner, titles: titles, liveness: liveness)
            cachedNavigation.reconcile(worktrees: cached, projects: [project])
            uncachedNavigation.reconcile(worktrees: uncached, projects: [project])
            for (actual, expected) in zip(cached, uncached) {
                #expect(cachedNavigation.worktreeContext(actual) == uncachedNavigation.worktreeContext(expected))
            }
            let merged = SidebarMergedRows.make(projects: [project], localRows: cached, remoteRows: [], localDeviceID: owner.deviceID, availability: { _ in .reachable })
            #expect(merged.selectedProjectID(for: cachedNavigation.selectedProjectID) == project.id)
            #expect(cachedNavigation.selectedProjectID == uncachedNavigation.selectedProjectID)
        }
    }
}
