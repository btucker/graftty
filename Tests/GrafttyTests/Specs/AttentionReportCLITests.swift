import Foundation
import GrafttyProtocol
import Testing
import GrafttyKit
@testable import GrafttyCLI

@Suite("Attention report CLI identity")
struct AttentionReportCLITests {
    @Test("@spec AGENT-3.22: When a new Attention report omits its task-specific emoji, the CLI shall reject it with an actionable error before staging it, while older saved recaps remain decodable.")
    func newReportsRequireEmoji() throws {
        var recap = AttentionRecap(title: "Push notifications", completed: "Wired the client.", next: "Test delivery.")
        let legacy = try JSONEncoder().encode(recap)
        #expect(try JSONDecoder().decode(AttentionRecap.self, from: legacy) == recap)
        do {
            _ = try AttentionReport.decodeRecap(legacy)
            Issue.record("A new report without an emoji was accepted")
        } catch {
            #expect(String(describing: error).contains("emoji"))
        }
        recap.emoji = "🔔"
        #expect(try AttentionReport.decodeRecap(JSONEncoder().encode(recap)) == recap)
    }
}
