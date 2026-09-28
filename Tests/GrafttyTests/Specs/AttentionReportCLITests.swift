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

    @Test("@spec AGENT-3.20: When a tracked Codex session has no wrapper registration, the CLI shall derive a stable report identity from its native session ID.")
    func codexNativeSessionProvidesFallbackIdentity() {
        let environment = ["CODEX_SESSION_ID": "thread-1"]
        let expected = TeamAgentIdentity(runtime: .codex, nativeSessionID: "thread-1").rawValue
        #expect(AttentionReportIdentity.unmanagedAgent(
            environment: environment
        )?.agentID == expected)
        #expect(AttentionReportIdentity.unmanagedAgent(
            environment: environment
        )?.sessionID == "thread-1")
    }
}
