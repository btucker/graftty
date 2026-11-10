import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct SidebarContextBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_SIDEBAR_BENCHMARK"] == "1"))
    func manyWorktreesAndRetainedReports() throws {
        let suite = "sidebar-benchmark-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reports = (0..<1200).map { index in
            SidebarActivityItem(id: "stable-\(index):stop", projectID: "project-\(index % 12)",
                worktreeID: "/synthetic/\(index)", paneID: nil, projectName: "Synthetic",
                worktreeName: "Task \(index)", title: "Review",
                occurrence: stop(index).occurrence, isBusy: false, agentStop: stop(index))
        }
        var workspace = SidebarAttentionWorkspace()
        workspace.merge(reports)
        defaults.set(try JSONEncoder().encode(workspace), forKey: "bench.attentionWorkspace")
        defaults.set(try JSONEncoder().encode(reports), forKey: "bench.worktreeReports")
        let rows = (0..<120).map { index in
            WorktreePanes(path: "/synthetic/\(index)", displayName: "Task \(index)", repoDisplayName: "Synthetic",
                displayBranch: "task-\(index)", state: .running, isMainCheckout: false,
                prBadge: nil, stats: nil, attentionText: nil,
                layout: .leaf(sessionName: "pane-\(index)", title: "Codex", attentionText: nil, isBusy: true, attentionSource: nil),
                sidebar: .init(id: "stable-\(index)", projectID: "project-\(index % 12)", unseenAgentStop: stop(index)))
        }
        var checksum = 0
        // Each trial includes navigation restoration and its first projection.
        // Six consumers approximate counts, sections, rows, search, and navigation.
        for trial in 0..<5 {
            let start = ContinuousClock.now
            let navigation = SidebarNavigationState(prefix: "bench", defaults: defaults)
            for _ in 0..<6 {
                for row in rows {
                    let context = navigation.worktreeContext(row)
                    checksum += context.pending.count
                    checksum += context.matches(query: "Review") ? 1 : 0
                }
            }
            print("SIDEBAR_BENCH trial=\(trial) elapsed=\(start.duration(to: .now)) rows=120 retained=2400 lookups=720")
        }
        #expect(checksum == 7200)
    }

    private func stop(_ index: Int) -> SidebarAgentStop {
        .init(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: Double(index + 100)),
              recap: .init(title: "Review", completed: "Synthetic change", next: "Inspect", need: "Approve?"))
    }
}
