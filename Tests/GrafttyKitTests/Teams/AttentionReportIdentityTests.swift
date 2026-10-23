import Foundation
import Testing
@testable import GrafttyKit

@Suite("Attention report identity")
struct AttentionReportIdentityTests {
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
