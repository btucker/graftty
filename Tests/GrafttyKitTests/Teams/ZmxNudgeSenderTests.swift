import Foundation
import Testing
@testable import GrafttyKit

@Suite("ZmxNudgeSender — pane-targeted in-process zmx-send")
struct ZmxNudgeSenderTests {
    @Test("@spec TEAM-IDLE-2.6: send invokes the writer with the resolved session name, the message text, and submit=true.")
    func writesToResolvedSession() async {
        let stubWriter = StubZmxWriter()
        let sender = ZmxNudgeSender(writer: stubWriter)
        let paneID = UUID()
        await sender.send(paneID: paneID, message: "hello", messageIDs: ["m-1"])
        #expect(stubWriter.writes.count == 1)
        #expect(stubWriter.writes[0].sessionName == ZmxLauncher.sessionName(for: paneID))
        #expect(stubWriter.writes[0].text == "hello")
        // submit:true tells AppZmxWriter to dispatch a real Return key
        // event after the text. The `\r` byte alone doesn't trigger TUI
        // submit handlers — Codex/Claude run in raw mode and parse key
        // events, not raw bytes — so a synthetic ghostty_surface_key call
        // for Return is required to make the typed message land.
        #expect(stubWriter.writes[0].submit == true)
    }

    final class StubZmxWriter: ZmxWriter, @unchecked Sendable {
        struct Call { let sessionName: String; let text: String; let submit: Bool }
        var writes: [Call] = []
        func write(sessionName: String, text: String, submit: Bool) async throws {
            writes.append(.init(sessionName: sessionName, text: text, submit: submit))
        }
    }
}
