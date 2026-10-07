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
                          progress: [String: Double] = [:], path: String = "/wt") -> WorktreePanes {
        .init(path: path, displayName: "Task", repoDisplayName: "Project", displayBranch: "task",
              state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
              layout: nil, sidebar: .init(id: path, projectID: "p", unseenAgentStop: unseen,
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
}
