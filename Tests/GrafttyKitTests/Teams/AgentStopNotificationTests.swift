import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

@Suite("Agent Stop Notification")
struct AgentStopNotificationTests {
    @Test("@spec NOTIF-1.4: When a stopped agent turn has a recap, the application shall send a macOS notification with its task title, worktree identity, and user question or completed result; a bare Stop shall remain silent.")
    func stoppedRecapUsesAttentionContent() throws {
        let recap = AttentionRecap(title: "Attention queue", completed: "Queue and banner tests pass.",
                                   next: "Review the sidebar.", need: "Does the banner look right?")
        var stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSince1970: 1_800_000_000), recap: recap)
        let content = try #require(AgentStopNotification.stoppedTurnContent(runtime: .codex,
            worktreeName: "sidebar", worktreePath: "/repo/sidebar", sessionID: "session", paneSessionName: "pane",
            stop: stop, emoji: "📥"))
        #expect(content.title == recap.title)
        #expect(content.subtitle == "📥 sidebar")
        #expect(content.body == recap.need)
        let payload = try AgentStopNotification.payload(from: content.userInfo)
        #expect(payload.worktreePath == "/repo/sidebar")
        #expect(payload.paneSessionName == "pane")
        stop.recap?.need = nil
        #expect(AgentStopNotification.stoppedTurnContent(runtime: .codex, worktreeName: "sidebar",
            worktreePath: "/repo/sidebar", sessionID: "session", paneSessionName: nil, stop: stop, emoji: nil)?.body == recap.completed)
        stop.recap = nil
        #expect(AgentStopNotification.stoppedTurnContent(runtime: .codex, worktreeName: "sidebar",
            worktreePath: "/repo/sidebar", sessionID: "session", paneSessionName: nil, stop: stop, emoji: nil) == nil)
    }

    @Test("@spec NOTIF-1.5: When another agent Attention notification is sent for the same worktree, the application shall replace its existing macOS notification while keeping other worktrees' notifications distinct.")
    func requestsShareWorktreeIdentity() throws {
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now,
            recap: .init(title: "Sidebar", completed: "Done.", next: "Review."))
        func content(_ path: String) throws -> AgentStopNotificationContent {
            try #require(AgentStopNotification.stoppedTurnContent(runtime: .codex, worktreeName: "sidebar",
                worktreePath: path, sessionID: "session", paneSessionName: nil, stop: stop, emoji: nil))
        }
        let first = try content("/repo/sidebar")
        let other = try content("/other/sidebar")
        let prompt = AgentStopNotification.content(runtime: .claude, worktreeName: "sidebar",
            worktreePath: "/repo/sidebar", sessionID: "different-session", paneSessionName: "pane",
            reason: .question, timestamp: .now)
        #expect(first.identifier != nil)
        #expect(first.identifier == prompt.identifier)
        #expect(first.identifier != other.identifier)
    }

    @Test func contentBuildsExpectedTitleBodyAndPayload() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let content = AgentStopNotification.content(
            runtime: .codex,
            worktreeName: "feature-auth",
            worktreePath: "/repo/.worktrees/feature-auth",
            sessionID: "codex:feature-auth:1",
            paneSessionName: "graftty-aaaa1111",
            reason: .permission,
            timestamp: timestamp
        )

        #expect(content.title == "Codex needs permission")
        #expect(content.body == "feature-auth requires your response.")
        #expect(content.userInfo["kind"] == "agent_stop")
        #expect(content.userInfo["attention_reason"] == "permission")
        #expect(content.userInfo["runtime"] == "codex")
        #expect(content.userInfo["worktree_path"] == "/repo/.worktrees/feature-auth")
        #expect(content.userInfo["session_id"] == "codex:feature-auth:1")
        #expect(content.userInfo["pane_session_name"] == "graftty-aaaa1111")
        #expect(content.userInfo["attention_timestamp"] == "2027-01-15T08:00:00Z")
    }

    @Test func contentOmitsPaneSessionNameWhenNil() throws {
        let content = AgentStopNotification.content(
            runtime: .codex,
            worktreeName: "wt",
            worktreePath: "/repo/wt",
            sessionID: "codex:wt:1",
            paneSessionName: nil,
            reason: .question,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(content.userInfo["pane_session_name"] == nil)
    }

    @Test func payloadParsesFromUserInfo() throws {
        let payload = try AgentStopNotification.payload(from: [
            "kind": "agent_stop",
            "runtime": "claude",
            "worktree_path": "/repo",
            "session_id": "claude:main:1",
            "pane_session_name": "graftty-bbbb2222",
            "attention_timestamp": "2027-01-15T08:00:00Z",
        ])

        #expect(payload.runtime == .claude)
        #expect(payload.worktreePath == "/repo")
        #expect(payload.sessionID == "claude:main:1")
        #expect(payload.paneSessionName == "graftty-bbbb2222")
        #expect(payload.attentionTimestamp == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func payloadPaneSessionNameNilWhenAbsent() throws {
        let payload = try AgentStopNotification.payload(from: [
            "kind": "agent_stop",
            "runtime": "claude",
            "worktree_path": "/repo",
            "session_id": "claude:main:1",
            "attention_timestamp": "2027-01-15T08:00:00Z",
        ])
        #expect(payload.paneSessionName == nil)
    }

    @Test func acknowledgeSelectionSelectsAndClearsAllAttention() {
        let ts = Date(timeIntervalSince1970: 1_800_000_000)
        var state = AppState(
            repos: [
                TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "feature-auth"]),
            ],
            selectedWorktreePath: nil
        )
        // Both worktree-scoped and a pane-scoped pill are present; the
        // notification-activation acknowledge must clear both (the pane
        // pill used to survive — the "never went away" bug).
        let slot = PaneSlotID(id: UUID())
        state.repos[0].worktrees[1].attention =
            Attention(text: "Codex needs input", timestamp: ts, source: .agentStop)
        state.repos[0].worktrees[1].paneAttention[slot] =
            Attention(text: "Codex needs input", timestamp: ts, source: .agentStop)

        AgentStopNotification.acknowledgeSelection(
            appState: &state,
            worktreePath: "/repo/.worktrees/feature-auth"
        )

        #expect(state.selectedWorktreePath == "/repo/.worktrees/feature-auth")
        #expect(state.repos[0].worktrees[1].attention == nil)
        #expect(state.repos[0].worktrees[1].paneAttention.isEmpty)
    }
}
