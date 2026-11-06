import Foundation
import GrafttyProtocol
import Testing
import GrafttyKit
@testable import GrafttyCLI

@Suite("Attention report CLI recap validation")
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

    @Test("@spec AGENT-3.37: When an Attention report carries a drawing that fails validation, the CLI shall reject the report with the specific reason before staging it.")
    func rejectsScriptIconWithReason() throws {
        var recap = AttentionRecap(title: "Parser cache", completed: "Cached parses.", next: "Measure.", emoji: "🗃️")
        recap.icon = "<svg viewBox=\"0 0 64 64\"><script>x()</script></svg>"
        do {
            _ = try AttentionReport.decodeRecap(JSONEncoder().encode(recap))
            Issue.record("An unsafe drawing was accepted")
        } catch {
            #expect(String(describing: error).contains("script"))
        }
        recap.icon = "<svg viewBox=\"0 0 64 64\"><g>\(String(repeating: " ", count: WorktreeDrawingSVG.maxBytes))</g></svg>"
        do {
            _ = try AttentionReport.decodeRecap(JSONEncoder().encode(recap))
            Issue.record("An oversized drawing was accepted")
        } catch {
            #expect(String(describing: error).contains("exceeds"))
        }
        recap.icon = "<svg viewBox=\"0 0 64 64\"><circle cx=\"32\" cy=\"32\" r=\"9\" fill=\"primary\"/></svg>"
        #expect(try AttentionReport.decodeRecap(JSONEncoder().encode(recap)).icon == recap.icon)
    }
}
