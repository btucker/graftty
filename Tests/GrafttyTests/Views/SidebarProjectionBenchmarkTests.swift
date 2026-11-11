import Foundation
import Testing
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI
@testable import Graftty

/// Synthetic paths only. No files, Git repositories, or terminal processes are created.
enum SidebarProjectionFixture {
    static let owner = WorktreeOrigin(deviceID: .init(value: "projection-benchmark"), deviceLabel: "Synthetic", relayDepth: 0)

    static func state(repositories: Int, rows: Int) -> AppState {
        AppState(repos: (0..<repositories).map { repository in
            let path = "/synthetic/projects/repo-\(repository)"
            let worktrees = (0..<rows).map { row in
                let worktreePath: String
                switch row {
                case 0: worktreePath = path
                case 1...5: worktreePath = "\(path)/.worktrees/research/task-\(row)"
                case 6...9: worktreePath = "/synthetic/external/repo-\(repository)/\(row)/checkout"
                default: worktreePath = "\(path)/.worktrees/fixes/task-\(row)"
                }
                let slot = PaneSlotID()
                var worktree = WorktreeEntry(path: worktreePath, branch: "feature/\(row)",
                    state: row % 4 == 0 ? .closed : .running,
                    createdAt: Date(timeIntervalSinceReferenceDate: Double(row)),
                    splitTree: .init(root: .leaf(slot)))
                worktree.paneSessions[slot] = PaneSessionID()
                worktree.isPinned = row < 3
                return worktree
            }
            return RepoEntry(path: path, displayName: "Repository \(repository)", worktrees: worktrees,
                             defaultBranchHint: "trunk")
        })
    }
}

@MainActor
struct SidebarProjectionBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_PROJECTION_BENCHMARK"] == "1"))
    func productionProjection() throws {
        let owner = SidebarProjectionFixture.owner
        for size in [(2, 8), (12, 16)] {
            let state = SidebarProjectionFixture.state(repositories: size.0, rows: size.1)
            let slots = state.repos.flatMap(\.worktrees).flatMap { $0.splitTree.allLeaves }
            let sessions = state.repos.flatMap(\.worktrees).flatMap { $0.paneSessions.values }.map(ZmxLauncher.sessionName(for:))
            let projects = state.repos.map {
                SidebarProject(id: "\(owner.deviceID.value):\($0.id.uuidString)", repositoryID: $0.path,
                               name: $0.displayName, owner: owner)
            }
            let suite = "projection-benchmark-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let navigation = SidebarNavigationState(prefix: "bench", defaults: defaults)
            var checksum = 0
            for trial in 0..<5 {
                for variant in ["uncached", "cached"] {
                    let cache = variant == "cached" ? SidebarLocalWorktreeMetadataCache() : nil
                    for mode in ["metadata", "projection", "live", "refresh", "cold"] {
                        let start = ContinuousClock.now
                        for iteration in 0..<10 {
                            if mode == "metadata" {
                                for repo in state.repos {
                                    let metadata = cache?.metadata(for: repo, defaultBranch: repo.defaultBranchHint)
                                        ?? SidebarLocalWorktreeMetadata(repo: repo, defaultBranch: repo.defaultBranchHint)
                                    checksum += metadata.ancestry.count + metadata.labels.count
                                }
                                continue
                            }
                            let titles = mode == "live" ? Dictionary(uniqueKeysWithValues: slots.map { ($0, "Title \(iteration)") }) : [:]
                            let liveness: [String: AgentLiveness] = mode == "live"
                                ? Dictionary(uniqueKeysWithValues: sessions.map { ($0, iteration % 2 == 0 ? .busy : .idle) }) : [:]
                            let iterationCache = mode == "cold" && cache != nil ? SidebarLocalWorktreeMetadataCache() : cache
                            let rows = sidebarLocalWorktrees(state: state, owner: owner, titles: titles, liveness: liveness, metadataCache: iterationCache)
                            checksum += rows.count
                            if mode == "refresh" {
                                navigation.reconcile(worktrees: rows, projects: projects)
                                // Mirrors refreshNavigation: reuse the local rows after the fix.
                                let mergedRows = cache == nil
                                    ? sidebarLocalWorktrees(state: state, owner: owner, titles: titles, liveness: liveness)
                                    : rows
                                checksum += SidebarMergedRows.make(projects: projects, localRows: mergedRows,
                                    remoteRows: [], localDeviceID: owner.deviceID, availability: { _ in .reachable }).projects.count
                            }
                        }
                        print("PROJECTION_BENCH rows=\(size.0 * size.1) variant=\(variant) mode=\(mode) trial=\(trial) iterations=10 elapsed=\(start.duration(to: .now))")
                    }
                }
            }
            #expect(checksum == 100 * (6 * size.0 * size.1 + size.0))
        }
    }
}
