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
}
