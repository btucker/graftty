import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec AGENT-3.20: When a tracked Codex session has no wrapper registration, the CLI shall derive a stable report identity from the first non-empty native session ID or thread ID.")
struct AttentionReportIdentityTests {
    @Test
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

    @Test("An empty CODEX_SESSION_ID does not hide the Codex thread ID")
    func emptySessionFallsBackToThread() throws {
        let agent = try #require(AttentionReportIdentity.unmanagedAgent(environment: [
            "CODEX_SESSION_ID": "",
            "CODEX_THREAD_ID": "thread-2",
            "CLAUDE_SESSION_ID": "claude-session",
        ]))
        #expect(agent.sessionID == "thread-2")
        #expect(agent.runtime == .codex)
        #expect(agent.agentID == TeamAgentIdentity(runtime: .codex, nativeSessionID: "thread-2").rawValue)
    }

    @Test("A non-empty Codex session ID takes precedence over its thread ID")
    func sessionTakesPrecedenceOverThread() {
        #expect(AttentionReportIdentity.unmanagedAgent(environment: [
            "CODEX_SESSION_ID": "session-1",
            "CODEX_THREAD_ID": "thread-2",
        ])?.sessionID == "session-1")
    }
}
