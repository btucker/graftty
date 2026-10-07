import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct SidebarWorktreeContextTests {
    private func stop(_ time: Double = 100) -> SidebarAgentStop {
        .init(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: time),
              recap: .init(title: "Reconnect", context: "Sleeping Mac", completed: "Reproduced", next: "Implement", need: "Retry silently?"),
              providerSessionKey: "agent")
    }

    private func worktree(unseen: SidebarAgentStop? = nil, last: SidebarAgentStop? = nil,
                          progress: [String: Double] = [:], path: String = "/wt", stableID: String? = nil, state: WorktreeWireState = .running, attention: String? = nil) -> WorktreePanes {
        .init(path: path, displayName: "Task", repoDisplayName: "Project", displayBranch: "task",
              state: state, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: attention,
              layout: nil, sidebar: .init(id: stableID ?? path, projectID: "p", unseenAgentStop: unseen,
                                         lastAgentStop: last, agentProgressTimes: progress))
    }

    @Test("@spec LAYOUT-2.125: When a worktree has an unacknowledged agent question, the application shall show the full question inline until it is opened, dismissed, superseded, or its agent resumes, while retaining the recap for preview.")
    func questionFollowsPendingOccurrence() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let navigation = SidebarNavigationState(prefix: "context", defaults: defaults)
        let row = worktree(unseen: stop(), last: stop())
        let initial = navigation.worktreeContext(row)
        #expect(initial.question == "Retry silently?")
        #expect(initial.pending.count == 1)
        let failed = navigation.beginOpening(initial.item)
        navigation.finishOpening(failed, succeeded: false)
        #expect(navigation.worktreeContext(row).question != nil)
        let opening = navigation.beginOpening(initial.item)
        navigation.finishOpening(opening, succeeded: true)
        #expect(navigation.worktreeContext(row).question == nil)
        #expect(navigation.worktreeContext(row).item.agentStop?.recap == stop().recap)
        #expect(navigation.worktreeContext(worktree(unseen: stop(101), last: stop(101))).question != nil)
        #expect(navigation.worktreeContext(worktree(last: stop(), progress: ["agent": 110])).question == nil)
        #expect(navigation.worktreeContext(worktree(last: stop(), progress: ["agent": 110])).isRunning)
    }

    @Test("@spec LAYOUT-2.126: When a remote client receives a retained agent recap, the application shall expose its context without counting it as a pending request and decode snapshots from older hosts without a retained recap.")
    func retainedReportAndOldSnapshots() throws {
        let row = worktree(last: stop())
        let restored = try JSONDecoder().decode(WorktreePanes.self, from: JSONEncoder().encode(row))
        let context = SidebarWorktreeContext(worktree: restored)
        #expect(context.item.agentStop == stop())
        #expect(context.pending.isEmpty)
        #expect(context.question == nil)
        let old = try JSONDecoder().decode(SidebarWorktreeMetadata.self, from: Data(#"{"id":"a","projectID":"p","folders":[]}"#.utf8))
        #expect(old.lastAgentStop == nil)
    }

    @Test("@spec LAYOUT-2.127: When worktree search matches a retained report field, the application shall include that worktree without acknowledging its pending request.")
    func searchReportFields() {
        let context = SidebarWorktreeContext(worktree: worktree(unseen: stop(), last: stop()))
        for query in ["Reconnect", "Sleeping", "Reproduced", "Implement", "silently", "Task"] {
            #expect(context.matches(query: query))
        }
        #expect(!context.matches(query: "unrelated"))
        #expect(context.pending.count == 1)
    }

    @Test("@spec LAYOUT-2.128: When pending-worktree navigation is invoked, the application shall select the next unviewed pending worktree in displayed order within the requested project and wrap at the end.")
    func pendingNavigationSkipsViewedAndWraps() throws {
        let navigation = SidebarNavigationState(prefix: UUID().uuidString)
        let a = worktree(unseen: stop(), path: "/a")
        let b = worktree(unseen: stop(), path: "/b")
        #expect(navigation.nextPendingWorktree(in: [a,b], projectID: "p", after: "/a")?.worktreeID == "/b")
        #expect(navigation.nextPendingWorktree(in: [a,a,b], projectID: "p", after: "/a")?.worktreeID == "/b")
        #expect(navigation.nextPendingWorktree(in: [a,b], projectID: "p", after: "/b")?.worktreeID == "/a")
        navigation.opened(navigation.worktreeContext(b).item)
        #expect(navigation.nextPendingWorktree(in: [a,b], projectID: "p", after: "/a")?.worktreeID == "/a")
        #expect(navigation.nextPendingWorktree(in: [a,b], projectID: "other", after: nil) == nil)
    }

    @Test func dismissalAndResumeDoNotHideNewReports() {
        let navigation = SidebarNavigationState(prefix: UUID().uuidString)
        let row = worktree(unseen: stop(), last: stop())
        navigation.reconcile(worktrees: [row], projects: [.init(id: "p", repositoryID: "r", name: "Project")])
        navigation.forget(navigation.worktreeContext(row).item.id)
        #expect(navigation.worktreeContext(row).question == nil)
        #expect(navigation.worktreeContext(worktree(unseen: stop(101), last: stop(101))).question != nil)
        #expect(SidebarWorktreeContext(worktree: worktree(unseen: stop(), last: stop(), progress: ["agent": 110])).pending.isEmpty)
    }

    @Test func olderHostKeepsDismissedReportAfterResumeAndRelaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let navigation = SidebarNavigationState(prefix: "legacy", defaults: defaults)
        let projects = [SidebarProject(id: "p", repositoryID: "r", name: "Project")]
        let row = worktree(unseen: stop())
        navigation.reconcile(worktrees: [row], projects: projects)
        navigation.forget(navigation.worktreeContext(row).item.id)
        let resumed = worktree(progress: ["agent": 110])
        navigation.reconcile(worktrees: [resumed], projects: projects)
        #expect(navigation.worktreeContext(resumed).item.agentStop?.recap == stop().recap)
        #expect(navigation.worktreeContext(resumed).question == nil)
        let restored = SidebarNavigationState(prefix: "legacy", defaults: defaults)
        #expect(restored.worktreeContext(resumed).item.agentStop?.recap == stop().recap)
    }

    @Test func delayedStopCannotBecomeAPendingTarget() {
        let navigation = SidebarNavigationState(prefix: UUID().uuidString)
        navigation.updateAttentionItems(SidebarProjection.activity([worktree(unseen: stop(110))]))
        let context = navigation.worktreeContext(worktree(unseen: stop(100)))
        #expect(context.item.agentStop?.timestamp == 110)
        #expect(context.pending.isEmpty)
    }
    @Test func frozenOrderRetainsMembershipAndLiveContent() {
        func row(_ path: String, pinned: Bool = false, folders: [String] = [], last: SidebarAgentStop? = nil) -> WorktreePanes {
            .init(path: path, displayName: path, repoDisplayName: "Project", displayBranch: path,
                  state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
                  sidebar: .init(id: path, projectID: "p", folders: folders, lastAgentStop: last, isPinned: pinned))
        }
        let a = row("a", folders: ["folder"]), b = row("b"), c = row("c", folders: ["folder"])
        let order = SidebarWorktreeReportOrder(worktrees: [a, b, c])
        let current = row("a", pinned: true, folders: ["moved"], last: stop(120))
        let frozen = order.orderedWorktrees([b, current, c])
        #expect(frozen.map(\.path) == ["a", "b", "c"])
        #expect(frozen[0].sidebar?.isPinned == false)
        #expect(frozen[0].sidebar?.folders == ["folder"])
        #expect(frozen[0].sidebar?.lastAgentStop == stop(120))
        #expect(SidebarWorktreeReportOrder.displayedWorktrees(frozen).map(\.path) == ["a", "c", "b"])
        #expect(order.orderedWorktrees([b, c]).map(\.path) == ["b", "c"])
    }

    @Test func retainedReportsFollowStableIdentityAcrossMovesAndPathReuse() {
        let navigation = SidebarNavigationState(prefix: UUID().uuidString)
        let projects = [SidebarProject(id: "p", repositoryID: "r", name: "Project")]
        let original = worktree(unseen: stop(), path: "/old", stableID: "stable")
        navigation.reconcile(worktrees: [original], projects: projects)
        navigation.forget(navigation.worktreeContext(original).item.id)
        let relocated = worktree(path: "/new", stableID: "stable")
        navigation.reconcile(worktrees: [relocated], projects: projects)
        #expect(navigation.worktreeContext(relocated).item.agentStop == stop())
        let replacement = worktree(path: "/new", stableID: "replacement")
        navigation.reconcile(worktrees: [replacement], projects: projects)
        #expect(navigation.worktreeContext(replacement).item.agentStop == nil)
    }

    @Test func closedWorktreeDoesNotShowRunningFromHistoricalProgress() {
        let context = SidebarWorktreeContext(worktree: worktree(unseen: stop(), last: stop(), progress: ["agent": 110], state: .closed))
        #expect(!context.isRunning)
        #expect(context.pending.isEmpty)
    }

    @Test func dismissTargetsPendingRequestAndPreservesNewerOccurrence() {
        let navigation = SidebarNavigationState(prefix: UUID().uuidString)
        let notification = worktree(last: stop(), attention: "Choose a device")
        let report = navigation.worktreeContext(notification)
        navigation.dismissRequest(in: report)
        #expect(navigation.worktreeContext(notification).pending.isEmpty)

        let old = navigation.worktreeContext(worktree(unseen: stop(120)))
        let newer = worktree(unseen: stop(130))
        navigation.updateAttentionItems(SidebarProjection.activity([newer]))
        navigation.dismissRequest(in: old)
        #expect(navigation.worktreeContext(newer).pending.count == 1)

        let another = SidebarNavigationState(prefix: UUID().uuidString)
        let captured = another.worktreeContext(notification)
        let incoming = worktree(unseen: stop(140), attention: "Choose a device")
        another.updateAttentionItems(SidebarProjection.activity([incoming]))
        another.dismissRequest(in: captured)
        #expect(another.worktreeContext(incoming).pending.contains { $0.agentStop?.timestamp == 140 })
    }

}
