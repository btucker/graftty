import Testing
import Foundation
@testable import EspalierKit

@Suite("Pane Message Types")
struct PaneMessageTests {
    @Test func paneSplitWireEncodesAsString() throws {
        let encoder = JSONEncoder()
        #expect(String(data: try encoder.encode(PaneSplitWire.right), encoding: .utf8) == "\"right\"")
        #expect(String(data: try encoder.encode(PaneSplitWire.left), encoding: .utf8) == "\"left\"")
        #expect(String(data: try encoder.encode(PaneSplitWire.up), encoding: .utf8) == "\"up\"")
        #expect(String(data: try encoder.encode(PaneSplitWire.down), encoding: .utf8) == "\"down\"")
    }

    @Test func paneSplitWireDecodesFromString() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(PaneSplitWire.self, from: "\"right\"".data(using: .utf8)!) == .right)
        #expect(try decoder.decode(PaneSplitWire.self, from: "\"down\"".data(using: .utf8)!) == .down)
    }

    @Test func paneInfoRoundTrip() throws {
        let info = PaneInfo(id: 2, title: "claude", focused: true)
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(PaneInfo.self, from: data)
        #expect(decoded.id == 2)
        #expect(decoded.title == "claude")
        #expect(decoded.focused == true)
    }

    @Test func paneInfoEncodesNilTitleAsMissing() throws {
        let info = PaneInfo(id: 1, title: nil, focused: false)
        let data = try JSONEncoder().encode(info)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["title"] == nil)
    }

    @Test func responseOkEncoding() throws {
        let data = try JSONEncoder().encode(ResponseMessage.ok)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "ok")
    }

    @Test func responseErrorEncoding() throws {
        let data = try JSONEncoder().encode(ResponseMessage.error("bad id"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "error")
        #expect(json["message"] as? String == "bad id")
    }

    @Test func responsePaneListEncoding() throws {
        let panes = [
            PaneInfo(id: 1, title: "zsh", focused: false),
            PaneInfo(id: 2, title: nil, focused: true),
        ]
        let data = try JSONEncoder().encode(ResponseMessage.paneList(panes))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "pane_list")
        let list = json["panes"] as! [[String: Any]]
        #expect(list.count == 2)
        #expect(list[0]["id"] as? Int == 1)
        #expect(list[1]["focused"] as? Bool == true)
    }

    @Test func responseRoundTrip() throws {
        let original = ResponseMessage.paneList([
            PaneInfo(id: 1, title: "zsh", focused: true),
            PaneInfo(id: 2, title: "claude", focused: false),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ResponseMessage.self, from: data)
        guard case .paneList(let panes) = decoded else {
            Issue.record("Expected .paneList")
            return
        }
        #expect(panes.count == 2)
        #expect(panes[0].title == "zsh")
        #expect(panes[1].focused == false)
    }

    @Test func responseErrorRoundTrip() throws {
        let data = try JSONEncoder().encode(ResponseMessage.error("nope"))
        let decoded = try JSONDecoder().decode(ResponseMessage.self, from: data)
        if case .error(let msg) = decoded {
            #expect(msg == "nope")
        } else { Issue.record("Expected .error") }
    }
}

@Suite("NotificationMessage Pane Cases")
struct NotificationMessagePaneTests {
    @Test func encodeListPanes() throws {
        let msg = NotificationMessage.listPanes(path: "/tmp/wt")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "list_panes")
        #expect(json["path"] as? String == "/tmp/wt")
    }

    @Test func encodeAddPaneNoCommand() throws {
        let msg = NotificationMessage.addPane(path: "/tmp/wt", direction: .right, command: nil)
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "add_pane")
        #expect(json["path"] as? String == "/tmp/wt")
        #expect(json["direction"] as? String == "right")
        #expect(json["command"] == nil)
    }

    @Test func encodeAddPaneWithCommand() throws {
        let msg = NotificationMessage.addPane(path: "/tmp/wt", direction: .down, command: "claude")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["direction"] as? String == "down")
        #expect(json["command"] as? String == "claude")
    }

    @Test func encodeClosePane() throws {
        let msg = NotificationMessage.closePane(path: "/tmp/wt", index: 2)
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "close_pane")
        #expect(json["path"] as? String == "/tmp/wt")
        #expect(json["index"] as? Int == 2)
    }

    @Test func decodeListPanes() throws {
        let json = #"{"type":"list_panes","path":"/tmp/wt"}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: json.data(using: .utf8)!)
        if case .listPanes(let path) = msg {
            #expect(path == "/tmp/wt")
        } else { Issue.record("Expected .listPanes") }
    }

    @Test func decodeAddPane() throws {
        let json = #"{"type":"add_pane","path":"/tmp/wt","direction":"left","command":"htop"}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: json.data(using: .utf8)!)
        if case .addPane(let path, let direction, let command) = msg {
            #expect(path == "/tmp/wt")
            #expect(direction == .left)
            #expect(command == "htop")
        } else { Issue.record("Expected .addPane") }
    }

    @Test func decodeAddPaneWithoutCommand() throws {
        let json = #"{"type":"add_pane","path":"/tmp/wt","direction":"right"}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: json.data(using: .utf8)!)
        if case .addPane(_, _, let command) = msg {
            #expect(command == nil)
        } else { Issue.record("Expected .addPane") }
    }

    @Test func decodeClosePane() throws {
        let json = #"{"type":"close_pane","path":"/tmp/wt","index":3}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: json.data(using: .utf8)!)
        if case .closePane(let path, let index) = msg {
            #expect(path == "/tmp/wt")
            #expect(index == 3)
        } else { Issue.record("Expected .closePane") }
    }

    @Test func existingNotifyStillDecodes() throws {
        // Regression: make sure adding cases didn't break the original two.
        let json = #"{"type":"notify","path":"/tmp/wt","text":"hi"}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: json.data(using: .utf8)!)
        if case .notify(_, let text, _) = msg {
            #expect(text == "hi")
        } else { Issue.record("Expected .notify") }
    }
}
