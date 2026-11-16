import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@MainActor
struct WorktreeContextLifecycleTests {
    private let start = Date(timeIntervalSinceReferenceDate: 100)

    @Test("@spec CONTEXT-69: When a provider resumes or later completes routine work, the application shall retain unread notices independently of stopped-turn activity until exact acknowledgement.")
    func noticesSurviveResumeAndLaterActivity() throws {
        var entry = WorktreeEntry(path: "/wt", branch: "fix")
        let notice = SidebarAgentStop(agentName: "Codex", stoppedAt: start,
            recap: .init(update: .init(attention: .init(kind: .notice, message: "Ready for review."))),
            providerSessionKey: "codex:one")
        entry.recordAgentStop(notice)
        entry.clearAgentStopAttention(providerSessionKey: "codex:one", progressedAt: start.addingTimeInterval(1))
        entry.recordAgentStop(.init(agentName: "Codex", stoppedAt: start.addingTimeInterval(2)))
        entry = try JSONDecoder().decode(WorktreeEntry.self, from: JSONEncoder().encode(entry))
        #expect(entry.unreadAgentNotices.count == 1)
        #expect(entry.hasAttention)
        #expect(entry.unreadAgentNotices.first?.notice == "Ready for review.")
        entry.acknowledgeAttention()
        #expect(entry.unreadAgentNotices.isEmpty)
        #expect(!entry.hasAttention)
    }

    @Test("@spec CONTEXT-70: When an agent completes a turn without an ask or notice, the application shall retain its activity and context without marking the worktree as needing attention.")
    func routineCompletionIsOnlyActivity() {
        var entry = WorktreeEntry(path: "/wt", branch: "fix")
        entry.recordAgentStop(.init(agentName: "Codex", stoppedAt: start))
        #expect(entry.lastAgentStop != nil)
        #expect(entry.unseenAgentStop != nil)
        #expect(!entry.hasAttention)
    }

    @Test func attentionAloneDoesNotInventContextAfterRestart() throws {
        var entry = WorktreeEntry(path: "/wt", branch: "fix")
        entry.recordAgentStop(.init(agentName: "Codex", stoppedAt: start,
            recap: .init(update: .init(attention: .init(kind: .notice, message: "Ready to review.")))))
        let restored = try JSONDecoder().decode(WorktreeEntry.self, from: JSONEncoder().encode(entry))
        #expect(restored.brief == nil)
    }

    @Test func drawingFreshnessIsIndependentOfProgress() {
        var state = AppState(repos: [.init(path: "/repo", displayName: "Repo", worktrees: [.init(path: "/wt", branch: "fix")])])
        state.recordAgentRecap(.init(title: "Startup fix", completed: "Started.", next: "Test."), callerPath: "/wt", reportedAt: start)
        state.recordAgentRecap(.init(update: .init(now: .init(summary: "Tests passed."))), callerPath: "/wt", reportedAt: start.addingTimeInterval(4))
        var update = WorktreeContextUpdate()
        update.icon = "<svg viewBox='0 0 96 64'><circle cx='48' cy='32' r='20' fill='primary'/></svg>"
        update.iconDescription = "A test circle"
        state.recordAgentRecap(.init(update: update), callerPath: "/wt", reportedAt: start.addingTimeInterval(2))
        #expect(state.repos[0].worktrees[0].drawing != nil)
        #expect(state.repos[0].worktrees[0].brief?.updatedAt == 104)
    }

    @Test("@spec CONTEXT-74: When a notice arrives after newer provider progress or routine activity, the application shall retain the notice without rewinding the latest activity or recreating it on a retried receipt.")
    func delayedNoticeStillNeedsReview() {
        var state = AppState(repos: [.init(path: "/repo", displayName: "Repo", worktrees: [.init(path: "/wt", branch: "fix")])])
        _ = state.recordStoppedTurn(callerPath: "/wt", runtime: .codex, callerAgentID: "agent", sessionID: "one",
            paneSessionName: nil, recap: .init(update: .init(unchanged: true)), stoppedAt: start.addingTimeInterval(2),
            recapReportedAt: start.addingTimeInterval(1), turnID: "second", paneTitle: { _, _ in nil })
        state.clearAgentAttention(callerPath: "/wt", callerAgentID: "agent", runtime: .codex, sessionID: "one", progressedAt: start.addingTimeInterval(3))
        let notice = AttentionRecap(update: .init(attention: .init(kind: .notice, message: "Ready to review.")))
        func deliver(_ state: inout AppState) -> AgentStopNotificationContent? {
            state.recordStoppedTurn(callerPath: "/wt", runtime: .codex, callerAgentID: "agent", sessionID: "one",
                paneSessionName: nil, recap: notice,
                stoppedAt: start, recapReportedAt: start.addingTimeInterval(-1), turnID: "first", paneTitle: { _, _ in nil })
        }
        #expect(deliver(&state)?.body == "Ready to review.")
        #expect(state.repos[0].worktrees[0].lastAgentStop?.stoppedAt == start.addingTimeInterval(2))
        #expect(state.repos[0].worktrees[0].unreadAgentNotices.count == 1)
        state.repos[0].worktrees[0].acknowledgeAttention()
        #expect(deliver(&state) == nil)
        #expect(state.repos[0].worktrees[0].unreadAgentNotices.isEmpty)
    }

    @Test("@spec CONTEXT-76: While additional agents share a worktree, the application shall preserve the primary agent's retained context and identity while retaining additional agents' explicit result notices.")
    func additionalAgentCannotReplacePrimaryContext() {
        let primary = ManagedAgent(name: "Primary", provider: .codex, parent: nil, isPrimary: true)
        let reviewer = ManagedAgent(name: "Reviewer", provider: .codex, parent: nil, isPrimary: false)
        var entry = WorktreeEntry(path: "/wt", branch: "fix")
        entry.agents = [primary, reviewer]
        var state = AppState(repos: [.init(path: "/repo", displayName: "Repo", worktrees: [entry])])
        state.recordAgentRecap(.init(title: "Startup fix", completed: "Fixed restoration.", next: "Review.", emoji: "🧪"),
            callerPath: "/wt", reportedAt: start, callerAgentID: primary.id)
        let other = AttentionRecap(title: "Review", completed: "Checked the diff.", next: "Finish.", emoji: "🔬", purposeChanged: true)
        state.recordAgentRecap(other, callerPath: "/wt", reportedAt: start.addingTimeInterval(1), callerAgentID: reviewer.id)
        _ = state.recordStoppedTurn(callerPath: "/wt", runtime: .codex, callerAgentID: reviewer.id,
            sessionID: "review", paneSessionName: nil,
            recap: .init(update: .init(attention: .init(kind: .notice, message: "Review notes ready."))),
            stoppedAt: start.addingTimeInterval(2), paneTitle: { _, _ in nil })
        #expect(state.repos[0].worktrees[0].brief?.title == "Startup fix")
        #expect(state.repos[0].worktrees[0].brief?.completed == "Fixed restoration.")
        #expect(state.repos[0].worktrees[0].emoji == "🧪")
        #expect(state.repos[0].worktrees[0].unreadAgentNotices.first?.notice == "Review notes ready.")
    }
}
