import Foundation
import Testing
@testable import GrafttyKit

@Suite("Agent Stop Notification")
struct AgentStopNotificationTests {
    @Test func contentBuildsExpectedTitleBodyAndPayload() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let content = AgentStopNotification.content(
            runtime: .codex,
            worktreeName: "feature-auth",
            worktreePath: "/repo/.worktrees/feature-auth",
            sessionID: "codex:feature-auth:1",
            paneSessionName: "graftty-aaaa1111",
            timestamp: timestamp
        )

        #expect(content.title == "Codex needs input")
        #expect(content.body == "feature-auth is waiting for you.")
        #expect(content.userInfo["kind"] == "agent_stop")
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

    @Test func acknowledgeSelectionClearsOnlyMatchingAttentionTimestamp() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let newer = timestamp.addingTimeInterval(1)
        var state = AppState(
            repos: [
                TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "feature-auth"]),
            ],
            selectedWorktreePath: nil
        )
        state.repos[0].worktrees[1].attention = Attention(text: "Codex needs input", timestamp: newer)

        AgentStopNotification.acknowledgeSelection(
            appState: &state,
            worktreePath: "/repo/.worktrees/feature-auth",
            timestamp: timestamp
        )

        #expect(state.selectedWorktreePath == "/repo/.worktrees/feature-auth")
        #expect(state.repos[0].worktrees[1].attention?.timestamp == newer)

        AgentStopNotification.acknowledgeSelection(
            appState: &state,
            worktreePath: "/repo/.worktrees/feature-auth",
            timestamp: newer
        )

        #expect(state.repos[0].worktrees[1].attention == nil)
    }
}
