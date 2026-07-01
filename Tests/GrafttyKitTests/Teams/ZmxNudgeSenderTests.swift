import Foundation
import Testing
@testable import GrafttyKit

@Suite("ZmxNudgeSender — session-targeted in-process zmx-send")
struct ZmxNudgeSenderTests {
    @Test("@spec TEAM-IDLE-2.6: send invokes the writer with the provided session name, the message text, and submit=true.")
    func writesToProvidedSession() async {
        let stubWriter = StubZmxWriter()
        let sender = ZmxNudgeSender(writer: stubWriter)
        let sent = await sender.send(sessionName: "graftty-explicit", message: "hello", messageIDs: ["m-1"])
        #expect(sent)
        #expect(stubWriter.writes.count == 1)
        #expect(stubWriter.writes[0].sessionName == "graftty-explicit")
        #expect(stubWriter.writes[0].text == "hello")
        // submit:true tells AppZmxWriter to dispatch a real Return key
        // event after the text. The `\r` byte alone doesn't trigger TUI
        // submit handlers — Codex/Claude run in raw mode and parse key
        // events, not raw bytes — so a synthetic ghostty_surface_key call
        // for Return is required to make the typed message land.
        #expect(stubWriter.writes[0].submit == true)
    }

    @Test("send returns false when the writer throws.")
    func returnsFalseWhenWriterThrows() async {
        let stubWriter = StubZmxWriter(error: StubError())
        let sender = ZmxNudgeSender(writer: stubWriter)

        let sent = await sender.send(sessionName: "graftty-explicit", message: "hello", messageIDs: ["m-1"])

        #expect(!sent)
        #expect(stubWriter.writes.count == 1)
    }

    struct StubError: Error {}

    final class StubZmxWriter: ZmxWriter, @unchecked Sendable {
        struct Call { let sessionName: String; let text: String; let submit: Bool }
        var writes: [Call] = []
        let error: (any Error)?

        init(error: (any Error)? = nil) {
            self.error = error
        }

        func write(sessionName: String, text: String, submit: Bool) async throws {
            writes.append(.init(sessionName: sessionName, text: text, submit: submit))
            if let error {
                throw error
            }
        }
    }
}
