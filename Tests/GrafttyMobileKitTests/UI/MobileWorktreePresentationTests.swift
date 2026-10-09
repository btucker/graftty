import Foundation
import GrafttyCommandUI
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

struct MobileWorktreePresentationTests {
    @Test("@spec IOS-9.11: While the mobile worktree list is not searching, the application shall display pinned agents across projects before temporary worktrees, preserving host order within each region and retaining a flat list for hosts without pin metadata.")
    func membershipRegionsPreserveHostOrder() {
        let rows = [row("task-a", project: "a", pinned: false),
                    row("pin-a", project: "a", pinned: true),
                    row("task-b", project: "b", pinned: false),
                    row("pin-b", project: "b", pinned: true)]
        let regions = WorktreePickerGrouping.regions(rows, searching: false)
        #expect(regions.map(\.kind) == [.pinned, .tasks])
        #expect(displayed(regions[0]).map(\.path) == ["pin-a", "pin-b"])
        #expect(displayed(regions[1]).map(\.path) == ["task-a", "task-b"])
        let legacy = [row("main"), row("feature")]
        let old = WorktreePickerGrouping.regions(legacy, searching: false)
        #expect(old.map(\.kind) == [.tasks])
        #expect(old.flatMap { displayed($0) } == legacy)
        #expect(WorktreePickerGrouping.regions([], searching: false).isEmpty)
    }

    @Test("Searching keeps host order and emits each matching worktree once")
    func searchDoesNotPartitionMembership() {
        let rows = [row("task", pinned: false), row("pin", pinned: true)]
        let regions = WorktreePickerGrouping.regions(rows, searching: true)
        #expect(regions.map(\.kind) == [.search])
        #expect(regions.flatMap(\.groups).flatMap(\.worktrees) == rows)
    }

    @Test("A main checkout without a pin flag inherits its group's membership metadata")
    func mainCheckoutDoesNotDisappearWhenPartitioning() {
        let main = WorktreePanes(path: "main", displayName: "main", repoDisplayName: "project",
            displayBranch: "main", state: .running, isMainCheckout: true, prBadge: nil,
            stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "main", projectID: "project"))
        let task = row("task", pinned: false)
        let regions = WorktreePickerGrouping.regions([task, main], searching: false)
        #expect(displayed(regions[0]) == [main])
        #expect(displayed(regions[1]) == [task])
    }

    private func displayed(_ region: WorktreePickerGrouping.Region) -> [WorktreePanes] {
        region.groups.flatMap {
            SidebarWorktreeReportOrder.displayedWorktrees($0.worktrees, section: region.sidebarSection)
        }
    }

    @Test("@spec IOS-9.12: When a mobile worktree question has no displayed matching pane, the application shall display it beneath the worktree, including empty layouts and non-running worktrees, without acknowledging its request.")
    func questionFallsBackToWorktree() {
        for layout in [nil, leaf("other", title: "Other"), leaf("reported", title: "Reported")] {
            for state in [WorktreeWireState.running, .closed, .stale] {
                let worktree = row("question", layout: layout, state: state, question: true)
                let context = SidebarWorktreeContext(worktree: worktree)
                let presentation = MobileWorktreeRowPresentation(context: context)
                let hasDisplayedMatch = state == .running && layout?.leaves.first?.sessionName == "reported"
                #expect(presentation.showsWorktreeQuestion == !hasDisplayedMatch)
                #expect(presentation.questionPaneID == (hasDisplayedMatch ? "reported" : nil))
                #expect(presentation.leaves.count == (state == .running ? layout?.leaves.count ?? 0 : 0))
                #expect(presentation.worktreeAttentionCount == (presentation.leaves.isEmpty ? 1 : 0))
                #expect(context.pending.count == 1)
            }
        }
        let noQuestion = MobileWorktreeRowPresentation(context: SidebarWorktreeContext(worktree: row("quiet")))
        #expect(!noQuestion.showsWorktreeQuestion)
        #expect(noQuestion.questionPaneID == nil)
    }

    private func leaf(_ session: String, title: String) -> PaneLayoutNode {
        .leaf(sessionName: session, title: title, attentionText: nil, isBusy: false, attentionSource: nil)
    }

    private func row(_ path: String, project: String = "project", pinned: Bool? = nil,
                     layout: PaneLayoutNode? = nil, state: WorktreeWireState = .running,
                     question: Bool = false) -> WorktreePanes {
        let stop = question ? SidebarAgentStop(agentName: "Codex", stoppedAt: .now,
            recap: .init(title: "Task", completed: "Ready", next: "Continue", need: "Ship this change?"),
            paneTitle: "Reported") : nil
        return .init(path: path, displayName: path, repoDisplayName: project, displayBranch: path,
            state: state, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: layout, sidebar: .init(id: path, projectID: project, unseenAgentStop: stop, isPinned: pinned))
    }
}
