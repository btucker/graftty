import Foundation
import Testing
@testable import GrafttyKit

@Suite("ZmxNudgeSender — pane-targeted in-process zmx-send")
struct ZmxNudgeSenderTests {
    @Test("@spec TEAM-IDLE-2.6: send invokes the writer with the resolved session name and payload.")
    func writesToResolvedSession() async {
        let stubWriter = StubZmxWriter()
        let sender = ZmxNudgeSender(writer: stubWriter)
        let paneID = UUID()
        await sender.send(paneID: paneID, message: "hello", messageIDs: ["m-1"])
        #expect(stubWriter.writes.count == 1)
        #expect(stubWriter.writes[0].sessionName == ZmxLauncher.sessionName(for: paneID))
        #expect(stubWriter.writes[0].text == "hello")
    }

    final class StubZmxWriter: ZmxWriter, @unchecked Sendable {
        struct Call { let sessionName: String; let text: String }
        var writes: [Call] = []
        func write(sessionName: String, text: String) async throws {
            writes.append(.init(sessionName: sessionName, text: text))
        }
    }
}
