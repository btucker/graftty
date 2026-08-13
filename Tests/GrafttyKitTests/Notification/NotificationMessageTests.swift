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
            callerAgentID: "codex-0123456789ab",
            recipient: "alice",
            text: "please review",
            priority: .urgent
        )
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_send")
        #expect(json["caller_worktree"] as? String == "/r/a")
        #expect(json["caller_agent_id"] as? String == "codex-0123456789ab")
        #expect(json["recipient"] as? String == "alice")
        #expect(json["text"] as? String == "please review")
        #expect(json["priority"] as? String == "urgent")

        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test func teamBroadcastRoundTripsWithPriority() throws {
        let original: NotificationMessage = .teamBroadcast(
            callerWorktree: "/r/a",
            callerAgentID: "claude-abcdef012345",
            text: "heads up",
            priority: .normal
        )
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_broadcast")
        #expect(json["caller_worktree"] as? String == "/r/a")
        #expect(json["caller_agent_id"] as? String == "claude-abcdef012345")
        #expect(json["text"] as? String == "heads up")
        #expect(json["priority"] as? String == "normal")

        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test("Older team-send payloads decode without caller agent identity.")
    func legacyTeamSendDecodesWithoutCallerAgentID() throws {
        let data = Data(#"{"type":"team_send","caller_worktree":"/r/a","recipient":"alice","text":"hello","priority":"normal"}"#.utf8)

        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)

        #expect(decoded == .teamSend(
            callerWorktree: "/r/a",
            callerAgentID: nil,
            recipient: "alice",
            text: "hello",
            priority: .normal
        ))
    }

    @Test func teamHookRoundTripsRuntimeEventAndSession() throws {
        let original: NotificationMessage = .teamHook(
            callerWorktree: "/r/a",
            callerAgentID: "codex-abcdef012345",
            runtime: .codex,
            event: .postToolUse,
            sessionID: "codex:a:123",
            paneSessionName: nil
        )
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_hook")
        #expect(json["caller_worktree"] as? String == "/r/a")
        #expect(json["caller_agent_id"] as? String == "codex-abcdef012345")
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
        guard case let .teamHook(_, _, _, _, _, paneSessionName, _) = decoded else {
            Issue.record("expected .teamHook"); return
        }
        #expect(paneSessionName == "graftty-abc12345")
    }

    @Test("Old .teamHook payload (no pane_session_name, no caller_agent_id) decodes the optional fields as nil.")
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
        guard case let .teamHook(_, callerAgentID, _, _, _, paneSessionName, _) = decoded else {
            Issue.record("expected .teamHook"); return
        }
        #expect(callerAgentID == nil)
        #expect(paneSessionName == nil)
    }

    @Test func teamInboxRoundTripsDiagnosticFilters() throws {
        let original: NotificationMessage = .teamInbox(TeamInboxPageRequest(
            callerWorktree: "/r/a",
            callerAgentID: "codex-0123456789ab",
            consuming: true,
            worktree: "feature-auth",
            repo: "/r",
            member: "main",
            unread: true,
            all: false,
            beforeID: "m0100",
            afterID: "m0001",
            snapshotThroughID: "m0200",
            forwardPagination: true,
            limit: 100
        ))
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_inbox")
        #expect(json["caller_worktree"] as? String == "/r/a")
        #expect(json["caller_agent_id"] as? String == "codex-0123456789ab")
        #expect(json["consuming"] as? Bool == true)
        #expect(json["worktree"] as? String == "feature-auth")
        #expect(json["repo"] as? String == "/r")
        #expect(json["member"] as? String == "main")
        #expect(json["unread"] as? Bool == true)
        #expect(json["all"] as? Bool == false)
        #expect(json["before_id"] as? String == "m0100")
        #expect(json["after_id"] as? String == "m0001")
        #expect(json["snapshot_through_id"] as? String == "m0200")
        #expect(json["forward_pagination"] as? Bool == true)
        #expect(json["limit"] as? Int == 100)

        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test func teamInboxAdvanceRequestRoundTrips() throws {
        let request = NotificationMessage.teamInboxAdvance(
            callerWorktree: "/r/a",
            callerAgentID: "codex-0123456789ab",
            throughID: "message-123"
        )
        let requestData = try JSONEncoder().encode(request)
        let requestJSON = try JSONSerialization.jsonObject(with: requestData) as! [String: Any]
        #expect(requestJSON["type"] as? String == "team_inbox_advance")
        #expect(requestJSON["caller_worktree"] as? String == "/r/a")
        #expect(requestJSON["caller_agent_id"] as? String == "codex-0123456789ab")
        #expect(requestJSON["through_id"] as? String == "message-123")
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: requestData) == request)

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
            base: "release/v2",
            command: "codex",
            agentRuntime: .codex,
            agentPrompt: "Fix the auth tests",
            operationID: "create-123"
        )
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "create_worktree")
        #expect(json["caller_worktree"] as? String == "/repo")
        #expect(json["worktree_name"] as? String == "fix-auth")
        #expect(json["branch_name"] as? String == "feature/fix-auth")
        #expect(json["base"] as? String == "release/v2")
        #expect(json["command"] as? String == "codex")
        #expect(json["agent_runtime"] as? String == "codex")
        #expect(json["agent_prompt"] as? String == "Fix the auth tests")
        #expect(json["operation_id"] as? String == "create-123")
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: data) == original)
    }

    @Test func createWorktreeRequestAcceptsLegacyPayloadWithoutAgentPrompt() throws {
        let data = Data(#"{"type":"create_worktree","caller_worktree":"/repo","worktree_name":"fix-auth","branch_name":"fix-auth","existing":false,"command":"codex","agent_runtime":"codex"}"#.utf8)
        let expected: NotificationMessage = .createWorktree(
            callerWorktree: "/repo",
            worktreeName: "fix-auth",
            branchName: "fix-auth",
            existing: false,
            base: nil,
            command: "codex",
            agentRuntime: .codex,
            agentPrompt: nil,
            operationID: nil
        )
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: data) == expected)
    }

    @Test func maximumAgentPromptFitsControlSocketAfterWorstCaseJSONEscaping() throws {
        let prompt = String(
            repeating: "\u{1}",
            count: WorktreeAgentLaunchCommand.maximumPromptBytes
        )
        let request: NotificationMessage = .createWorktree(
            callerWorktree: "/repo",
            worktreeName: "fix-auth",
            branchName: "fix-auth",
            existing: false,
            base: nil,
            command: "codex",
            agentRuntime: .codex,
            agentPrompt: prompt,
            operationID: "create-maximum-prompt"
        )

        #expect(try JSONEncoder().encode(request).count < 1 * 1_024 * 1_024)
    }

    @Test func agentPromptStagingCapabilityRequestRoundTrips() throws {
        let request = NotificationMessage.agentPromptStagingCapability
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "agent_prompt_staging_capability")
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: data) == request)
    }

    @Test func worktreeBaseCapabilityRequestRoundTrips() throws {
        let request = NotificationMessage.worktreeBaseCapability
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "worktree_base_capability")
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: data) == request)
    }

    @Test func worktreeCreateIdempotencyCapabilityRequestRoundTrips() throws {
        let request = NotificationMessage.worktreeCreateIdempotencyCapability
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "worktree_create_idempotency_capability")
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: data) == request)
    }

    @Test func worktreeCreateStatusRequestRoundTrips() throws {
        let original: NotificationMessage = .worktreeCreateStatus(operationID: "op-123")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: data) == original)
    }

    @Test func removeWorktreeRequestRoundTrips() throws {
        let original: NotificationMessage = .removeWorktree(
            worktreePath: "/repo/.worktrees/feature",
            force: true
        )
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "remove_worktree")
        #expect(json["worktree_path"] as? String == "/repo/.worktrees/feature")
        #expect(json["force"] as? Bool == true)
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: data) == original)
    }

    @Test func worktreeRemoveCapabilityRequestRoundTrips() throws {
        let request = NotificationMessage.worktreeRemoveCapability
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "worktree_remove_capability")
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: data) == request)
    }

    @Test func worktreeRemoveStatusRequestRoundTrips() throws {
        let original: NotificationMessage = .worktreeRemoveStatus(operationID: "op-remove")
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

    @Test func worktreeRemoveResponseRoundTripsForceableFailure() throws {
        let status = WorktreeRemoveStatus(
            operationID: "op-remove",
            state: .failed,
            worktreePath: "/repo/.worktrees/feature",
            error: "contains modified or untracked files",
            forceAllowed: true,
            shortStatus: "?? scratch.txt"
        )
        let original: ResponseMessage = .worktreeRemove(status)
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "worktree_remove")
        let operation = json["operation"] as! [String: Any]
        #expect(operation["force_allowed"] as? Bool == true)
        #expect(operation["short_status"] as? String == "?? scratch.txt")
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
        let original = ResponseMessage.teamInbox(
            messages: [message],
            nextBeforeID: "0001",
            nextAfterID: "0002",
            snapshotThroughID: "0010"
        )
        let data = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "team_inbox")
        let messages = json["messages"] as! [[String: Any]]
        #expect(messages.count == 1)
        #expect(json["next_before_id"] as? String == "0001")
        #expect(json["next_after_id"] as? String == "0002")
        #expect(json["snapshot_through_id"] as? String == "0010")

        let decoded = try JSONDecoder().decode(ResponseMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test func finalTeamInboxPageDecodesWithoutPaginationCursor() throws {
        let json = #"{"type":"team_inbox","messages":[]}"#
        let decoded = try JSONDecoder().decode(ResponseMessage.self, from: Data(json.utf8))
        #expect(decoded == .teamInbox(
            messages: [],
            nextBeforeID: nil,
            nextAfterID: nil,
            snapshotThroughID: nil
        ))
    }

    @Test func teamInboxRequestWithoutPaginationFieldsDecodesForExplicitRejection() throws {
        let json = #"{"type":"team_inbox","caller_worktree":"/r","unread":false,"all":true}"#
        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: Data(json.utf8))
        #expect(decoded == .teamInbox(TeamInboxPageRequest(
            callerWorktree: "/r",
            worktree: nil,
            repo: nil,
            member: nil,
            unread: false,
            all: true,
            beforeID: nil,
            afterID: nil,
            snapshotThroughID: nil,
            forwardPagination: nil,
            limit: nil
        )))
    }

    @Test("@spec TEAM-4.6: When a team member-list command is invoked with `--json`, the CLI shall emit a Codable document with `team` and `members`, using the existing snake_case `TeamListMember` wire keys rather than human-formatted rows.")
    func teamListDocumentUsesStableJSONKeys() throws {
        let document = TeamListDocument(
            team: "acme",
            members: [
                TeamListMember(
                    name: "main",
                    branch: "main",
                    worktreePath: "/r",
                    isMainWorktree: true,
                    isRunning: true
                ),
            ]
        )
        let data = try JSONEncoder().encode(document)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["team"] as? String == "acme")
        let members = json["members"] as! [[String: Any]]
        #expect(members[0]["worktree_path"] as? String == "/r")
        #expect(members[0]["is_main_worktree"] as? Bool == true)
        #expect(members[0]["is_running"] as? Bool == true)
    }
}
