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
        if case .notify(let path, let text, let clearAfter) = msg {
            #expect(path == "/tmp/wt")
            #expect(text == "Build failed")
            #expect(clearAfter == nil)
        } else { Issue.record("Expected .notify") }
    }

    @Test func decodeClear() throws {
        let json = #"{"type": "clear", "path": "/tmp/wt"}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: json.data(using: .utf8)!)
        if case .clear(let path) = msg {
            #expect(path == "/tmp/wt")
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

    @Test func encodeTeamListResponse() throws {
        let resp: ResponseMessage = .teamList(
            teamName: "acme-web",
            members: [
                .init(name: "main", branch: "main", worktreePath: "/r/a", role: "lead", isRunning: true),
                .init(name: "alice", branch: "alice", worktreePath: "/r/a/.worktrees/alice", role: "coworker", isRunning: false),
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
            {"name":"main","branch":"main","worktree_path":"/r/a","role":"lead","is_running":true},
            {"name":"alice","branch":"alice","worktree_path":"/r/a/.worktrees/alice","role":"coworker","is_running":false}
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
        #expect(members[0].role == "lead")
        #expect(members[0].isRunning == true)
        #expect(members[1].worktreePath == "/r/a/.worktrees/alice")
        #expect(members[1].isRunning == false)
    }
}
