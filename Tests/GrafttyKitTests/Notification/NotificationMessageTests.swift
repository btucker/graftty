import Testing
import Foundation
@testable import GrafttyKit

@Suite("NotificationMessage Tests")
struct NotificationMessageTests {
    @Test func encodeNotify() throws {
        let msg = NotificationMessage.notify(path: "/tmp/wt", text: "Build failed")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "notify")
        #expect(json["path"] as? String == "/tmp/wt")
        #expect(json["text"] as? String == "Build failed")
        #expect(json["clearAfter"] == nil)
    }

    @Test func encodeNotifyWithClearAfter() throws {
        let msg = NotificationMessage.notify(path: "/tmp/wt", text: "Done", clearAfter: 10)
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["clearAfter"] as? Int == 10)
    }

    @Test func encodeClear() throws {
        let msg = NotificationMessage.clear(path: "/tmp/wt")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "clear")
        #expect(json["path"] as? String == "/tmp/wt")
    }

    @Test func decodeNotify() throws {
        let json = #"{"type": "notify", "path": "/tmp/wt", "text": "Build failed"}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: json.data(using: .utf8)!)
        if case .notify(let path, let text, let clearAfter, let paneSessionName) = msg {
            #expect(path == "/tmp/wt")
            #expect(text == "Build failed")
            #expect(clearAfter == nil)
            #expect(paneSessionName == nil)
        } else { Issue.record("Expected .notify") }
    }

    @Test func decodeClear() throws {
        let json = #"{"type": "clear", "path": "/tmp/wt"}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: json.data(using: .utf8)!)
        if case .clear(let path, let paneSessionName) = msg {
            #expect(path == "/tmp/wt")
            #expect(paneSessionName == nil)
        } else { Issue.record("Expected .clear") }
    }

    @Test func encodeTeamMessage() throws {
        let msg: NotificationMessage = .teamMessage(callerWorktree: "/r/a", recipient: "alice", text: "hi")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_message")
        #expect(json["caller_worktree"] as? String == "/r/a")
        #expect(json["recipient"] as? String == "alice")
        #expect(json["text"] as? String == "hi")
    }

    @Test func decodeTeamMessage() throws {
        let json = #"{"type":"team_message","caller_worktree":"/r/a","recipient":"alice","text":"hi"}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: Data(json.utf8))
        guard case let .teamMessage(caller, recipient, text) = msg else {
            Issue.record("expected .teamMessage")
            return
        }
        #expect(caller == "/r/a")
        #expect(recipient == "alice")
        #expect(text == "hi")
    }

    @Test func encodeTeamList() throws {
        let msg: NotificationMessage = .teamList(callerWorktree: "/r/a")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_list")
        #expect(json["caller_worktree"] as? String == "/r/a")
    }

    @Test func teamSendRoundTripsWithPriority() throws {
        let original: NotificationMessage = .teamSend(
            callerWorktree: "/r/a",
            recipient: "alice",
            text: "please review",
            priority: .urgent
        )
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_send")
        #expect(json["caller_worktree"] as? String == "/r/a")
        #expect(json["recipient"] as? String == "alice")
        #expect(json["text"] as? String == "please review")
        #expect(json["priority"] as? String == "urgent")

        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test func teamBroadcastRoundTripsWithPriority() throws {
        let original: NotificationMessage = .teamBroadcast(
            callerWorktree: "/r/a",
            text: "heads up",
            priority: .normal
        )
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_broadcast")
        #expect(json["caller_worktree"] as? String == "/r/a")
        #expect(json["text"] as? String == "heads up")
        #expect(json["priority"] as? String == "normal")

        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test func teamHookRoundTripsRuntimeEventAndSession() throws {
        let original: NotificationMessage = .teamHook(
            callerWorktree: "/r/a",
            runtime: .codex,
            event: .postToolUse,
            sessionID: "codex:a:123",
            paneSessionName: nil
        )
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_hook")
        #expect(json["caller_worktree"] as? String == "/r/a")
        #expect(json["runtime"] as? String == "codex")
        #expect(json["event"] as? String == "post-tool-use")
        #expect(json["session_id"] as? String == "codex:a:123")

        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test("@spec TEAM-IDLE-2.9: .teamHook encodes and decodes paneSessionName when present.")
    func teamHookRoundTripsPaneSessionName() throws {
        let original: NotificationMessage = .teamHook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .codex,
            event: .stop,
            sessionID: "codex-internal-id",
            paneSessionName: "graftty-abc12345"
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: encoded)
        guard case let .teamHook(_, _, _, _, paneSessionName) = decoded else {
            Issue.record("expected .teamHook"); return
        }
        #expect(paneSessionName == "graftty-abc12345")
    }

    @Test("Old .teamHook payload (no pane_session_name) decodes paneSessionName as nil.")
    func teamHookOldPayloadDecodesNil() throws {
        let oldJSON = """
        {
          "type": "team_hook",
          "caller_worktree": "/repo/.worktrees/alice",
          "runtime": "codex",
          "event": "stop"
        }
        """
        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: oldJSON.data(using: .utf8)!)
        guard case let .teamHook(_, _, _, _, paneSessionName) = decoded else {
            Issue.record("expected .teamHook"); return
        }
        #expect(paneSessionName == nil)
    }

    @Test func teamInboxRoundTripsDiagnosticFilters() throws {
        let original: NotificationMessage = .teamInbox(
            callerWorktree: "/r/a",
            worktree: "feature-auth",
            repo: "/r",
            member: "main",
            unread: true,
            all: false
        )
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_inbox")
        #expect(json["caller_worktree"] as? String == "/r/a")
        #expect(json["worktree"] as? String == "feature-auth")
        #expect(json["repo"] as? String == "/r")
        #expect(json["member"] as? String == "main")
        #expect(json["unread"] as? Bool == true)
        #expect(json["all"] as? Bool == false)

        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test func teamMembersRoundTripsDiagnosticScope() throws {
        let original: NotificationMessage = .teamMembers(
            callerWorktree: nil,
            worktree: "feature-auth",
            repo: "/r"
        )
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_members")
        #expect(json["caller_worktree"] == nil)
        #expect(json["worktree"] as? String == "feature-auth")
        #expect(json["repo"] as? String == "/r")

        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test func encodeTeamListResponse() throws {
        let resp: ResponseMessage = .teamList(
            teamName: "acme-web",
            members: [
                .init(name: "main", branch: "main", worktreePath: "/r/a", isMainWorktree: true, isRunning: true),
                .init(name: "alice", branch: "alice", worktreePath: "/r/a/.worktrees/alice", isMainWorktree: false, isRunning: false),
            ]
        )
        let data = try JSONEncoder().encode(resp)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_list")
        #expect(json["team_name"] as? String == "acme-web")
        let members = json["members"] as! [[String: Any]]
        #expect(members.count == 2)
    }

    @Test func decodeTeamListResponse() throws {
        let json = #"""
        {
          "type": "team_list",
          "team_name": "acme-web",
          "members": [
            {"name":"main","branch":"main","worktree_path":"/r/a","is_main_worktree":true,"is_running":true},
            {"name":"alice","branch":"alice","worktree_path":"/r/a/.worktrees/alice","is_main_worktree":false,"is_running":false}
          ]
        }
        """#
        let resp = try JSONDecoder().decode(ResponseMessage.self, from: Data(json.utf8))
        guard case let .teamList(teamName, members) = resp else {
            Issue.record("expected .teamList")
            return
        }
        #expect(teamName == "acme-web")
        #expect(members.count == 2)
        #expect(members[0].name == "main")
        #expect(members[0].isMainWorktree)
        #expect(members[0].isRunning == true)
        #expect(members[1].worktreePath == "/r/a/.worktrees/alice")
        #expect(members[1].isRunning == false)
    }

    @Test func teamHookOutputResponseRoundTrips() throws {
        let original = ResponseMessage.teamHookOutput(#"{"hookSpecificOutput":{}}"#)
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_hook_output")
        #expect(json["output"] as? String == #"{"hookSpecificOutput":{}}"#)

        let decoded = try JSONDecoder().decode(ResponseMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test func showPaneRoundTrip() throws {
        let original: NotificationMessage = .showPane(path: "/wt", index: 2, lines: 100)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
        #expect(decoded == original)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["type"] as? String == "show_pane")
    }

    @Test func sendPaneRoundTrip() throws {
        let original: NotificationMessage = .sendPane(path: "/wt", index: 1, text: "ls\n", pressEnter: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
        #expect(decoded == original)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["type"] as? String == "send_pane")
    }

    @Test func createWorktreeRequestRoundTrips() throws {
        let original: NotificationMessage = .createWorktree(
            callerWorktree: "/repo",
            worktreeName: "fix-auth",
            branchName: "feature/fix-auth",
            existing: false,
            command: "codex",
            agentRuntime: .codex
        )
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "create_worktree")
        #expect(json["caller_worktree"] as? String == "/repo")
        #expect(json["worktree_name"] as? String == "fix-auth")
        #expect(json["branch_name"] as? String == "feature/fix-auth")
        #expect(json["command"] as? String == "codex")
        #expect(json["agent_runtime"] as? String == "codex")
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: data) == original)
    }

    @Test func worktreeCreateStatusRequestRoundTrips() throws {
        let original: NotificationMessage = .worktreeCreateStatus(operationID: "op-123")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: data) == original)
    }

    @Test func worktreeCreateResponseRoundTrips() throws {
        let status = WorktreeCreateStatus(
            operationID: "op-123",
            state: .ready,
            worktreePath: "/repo/.worktrees/fix-auth",
            messageAddress: "/repo/.worktrees/fix-auth"
        )
        let original: ResponseMessage = .worktreeCreate(status)
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "worktree_create")
        let operation = json["operation"] as! [String: Any]
        #expect(operation["message_address"] as? String == "/repo/.worktrees/fix-auth")
        #expect(try JSONDecoder().decode(ResponseMessage.self, from: data) == original)
    }

    @Test func paneShowResponseRoundTrip() throws {
        let original: ResponseMessage = .paneShow("hello\nworld\n")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ResponseMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test func teamInboxResponseRoundTripsMessages() throws {
        let message = TeamInboxMessage(
            id: "0001",
            batchID: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            team: "acme-web",
            repoPath: "/r",
            from: .init(member: "alice", worktree: "/r/.worktrees/alice", runtime: "codex"),
            to: .init(member: "main", worktree: "/r", runtime: nil),
            priority: .normal,
            body: "hello"
        )
        let original = ResponseMessage.teamInbox([message])
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_inbox")
        let messages = json["messages"] as! [[String: Any]]
        #expect(messages.count == 1)

        let decoded = try JSONDecoder().decode(ResponseMessage.self, from: data)
        #expect(decoded == original)
    }
}
