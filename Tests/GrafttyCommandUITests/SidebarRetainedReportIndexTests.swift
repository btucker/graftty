import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

struct SidebarRetainedReportIndexTests {
    @Test("@spec LAYOUT-2.231: When a sidebar worktree context is projected, the application shall look up retained reports by its exact stable stop identifier or, for older hosts, its project and path, preserving report order without scanning unrelated reports.")
    func indexedCandidatesMatchExistingIdentityRules() {
        let reports = [item("stable:stop", "other", "/moved"), item("stable:pane", "connected:p", "/wt"),
                       item("unrelated:stop", "connected:p", "/wt"), item("stable:stop", "connected:p", "/wt"),
                       item("different:stop", "connected:remote", "/wt"), item("prefix:stable:stop", "connected:p", "/else")]
        let index = SidebarRetainedReportIndex(sources: [Array(reports.prefix(3)), Array(reports.suffix(3))])
        for row in [row(stableID: "stable"), row(), row(project: "remote"), row(path: "/else"),
                    row(stableID: "stable:pane"), row(project: "missing")] {
            #expect(index.reports(for: row) == reports.filter { SidebarWorktreeContext.matchesRetainedReport($0, worktree: row) })
        }
        #expect(index.reports(for: row(stableID: "stable")).count == 2)
        #expect(index.reports(for: row()).count == 3)
    }

    @Test func manyUnrelatedReportsDoNotReachContextFiltering() {
        let reports = (0..<1200).map { item("stable-\($0):stop", "p", "/synthetic/\($0)") }
        let index = SidebarRetainedReportIndex(sources: [reports, reports])
        var candidates = 0
        for _ in 0..<6 {
            for number in 0..<120 {
                candidates += index.reports(for: row(stableID: "stable-\(number)")).count
            }
        }
        #expect(candidates == 1440)
    }

    private func item(_ id: String, _ project: String, _ path: String) -> SidebarActivityItem {
        .init(id: id, projectID: project, worktreeID: path, paneID: nil, projectName: project,
              worktreeName: path, title: id, occurrence: nil, isBusy: false)
    }

    private func row(stableID: String? = nil, project: String = "p", path: String = "/wt") -> WorktreePanes {
        .init(path: path, displayName: "Task", repoDisplayName: "Project", repositoryID: project,
              displayBranch: "task", state: .running, isMainCheckout: false, prBadge: nil,
              stats: nil, attentionText: nil, layout: nil,
              sidebar: stableID.map { .init(id: $0, projectID: project) })
    }
}
