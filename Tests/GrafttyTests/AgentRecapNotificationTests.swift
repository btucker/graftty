import Testing
import SwiftUI
import UserNotifications
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@MainActor
struct AgentRecapNotificationTests {
    @Test("@spec NOTIF-1.6: While Graftty is active, agent Attention notifications shall display native banners and sounds using the user's macOS notification settings.")
    func foregroundAgentNotificationsAreVisible() {
        #expect(AgentNotificationRouter.foregroundPresentationOptions(kind: "agent_stop") == [.banner, .sound])
        #expect(AgentNotificationRouter.foregroundPresentationOptions(kind: "remote_attention") == [.banner, .sound])
        #expect(AgentNotificationRouter.foregroundPresentationOptions(kind: nil).isEmpty)
    }

    @Test("@spec NOTIF-1.7: When a stopped recap reaches Graftty through the hook or file handoff, the application shall post its desktop notification once and ignore duplicate deliveries or stops older than a recorded stop or that provider's progress.")
    func recordingAStoppedRecapPostsOnce() {
        var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "Repo",
            worktrees: [WorktreeEntry(path: "/repo/sidebar", branch: "sidebar")])])
        let binding = Binding<AppState>(get: { state }, set: { state = $0 })
        let manager = TerminalManager(socketPath: "/tmp/graftty-recap-notification-test.sock")
        let recap = AttentionRecap(title: "Attention queue", completed: "Tests passed.", next: "Review.", emoji: "📥")
        var notifications: [AgentStopNotificationContent] = []
        func record(_ time: Double, recap: AttentionRecap?) {
            GrafttyApp.recordStoppedTurn(callerPath: "/repo/sidebar", runtime: .codex,
                callerAgentID: "agent", sessionID: "session", paneSessionName: nil, recap: recap,
                stoppedAt: Date(timeIntervalSince1970: time), appState: binding, terminalManager: manager,
                postNotification: { notifications.append($0) })
        }
        record(100, recap: recap)
        record(100, recap: recap)
        record(90, recap: recap)
        #expect(notifications.count == 1)
        if let notification = notifications.first {
            let request = AgentNotificationRouter.request(for: notification)
            #expect(request.identifier == notification.identifier)
            #expect(request.content.title == recap.title)
            #expect(request.content.subtitle == "📥 sidebar")
            #expect(request.content.body == recap.completed)
            #expect(request.content.sound != nil)
            #expect(request.content.userInfo["worktree_path"] as? String == "/repo/sidebar")
        }
        #expect(state.repos[0].worktrees[0].unseenAgentStop?.stoppedAt == Date(timeIntervalSince1970: 100))
        record(200, recap: recap)
        #expect(notifications.count == 2)
        #expect(notifications[0].identifier == notifications[1].identifier)
        record(300, recap: nil)
        #expect(notifications.count == 2)
        state.repos[0].worktrees[0].clearAgentStopAttention(
            providerSessionKey: "codex:session:session", progressedAt: Date(timeIntervalSince1970: 400))
        record(350, recap: recap)
        #expect(notifications.count == 2)
        #expect(state.repos[0].worktrees[0].unseenAgentStop == nil)
        record(450, recap: recap)
        #expect(notifications.count == 3)
    }
}
