import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec AGENT-3.20: When a tracked Codex session has no wrapper registration, the CLI shall derive a stable report identity from the first non-empty thread ID or native session ID.")
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

    @Test("A Codex thread ID takes precedence over a shared ancestor session ID")
    func threadTakesPrecedenceOverSharedSession() {
        #expect(AttentionReportIdentity.unmanagedAgent(environment: [
            "CODEX_SESSION_ID": "session-1",
            "CODEX_THREAD_ID": "thread-2",
        ])?.sessionID == "thread-2")
    }
}

@Suite("Sandboxed Attention identity")
struct SandboxedAttentionIdentityTests {
    @Test("@spec AGENT-3.26: When an agent reports from a sandbox that cannot inspect its delivery socket, the application shall resolve its registered identity using current process identity and worktree and pane ownership without requiring socket reachability.")
    func resolvesWithoutSocketMetadata() throws {
        let presence = TeamPresenceRecord(teamID: "/repo", worktree: "/repo", runtime: .codex,
            paneSessionName: "pane", pid: Int32(ProcessInfo.processInfo.processIdentifier),
            processStartTimeMicroseconds: ProcessIdentityReader.startTimeMicroseconds(ofPID: Int32(ProcessInfo.processInfo.processIdentifier)),
            registeredAt: Date(), runtimeSessionID: "thread", agentID: "codex-012345abcdef",
            transport: .codex(binaryPath: "/codex", socketPath: "/inaccessible/socket", threadID: "thread", activeTurnID: nil))
        #expect(!TeamAgentReachability.isReachable(presence))
        #expect(AttentionReportIdentity.currentAgentID(worktreePath: "/repo",
            environment: ["GRAFTTY_AGENT_ID": "codex-012345abcdef", "ZMX_SESSION": "pane"],
            records: [presence], isReachable: AttentionReportIdentity.hasCurrentProcessIdentity) == "codex-012345abcdef")
    }
    @Test("Socket-independent reports reject stale processes and foreign ownership",
          arguments: ["worktree", "pane", "subagent", "reused-pid", "unknown-start", "missing-pid"])
    func rejectsUnownedRegistration(_ scenario: String) {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let start = ProcessIdentityReader.startTimeMicroseconds(ofPID: pid)
        let presence = TeamPresenceRecord(teamID: "/repo", worktree: scenario == "worktree" ? "/other" : "/repo",
            runtime: .codex, paneSessionName: scenario == "pane" ? "other-pane" : "pane",
            pid: scenario == "missing-pid" ? -1 : pid,
            processStartTimeMicroseconds: scenario == "unknown-start" ? nil : (scenario == "reused-pid" ? 0 : start),
            registeredAt: Date(), runtimeSessionID: "thread", agentID: "codex-012345abcdef",
            isSubagent: scenario == "subagent")
        #expect(AttentionReportIdentity.currentAgentID(worktreePath: "/repo",
            environment: ["GRAFTTY_AGENT_ID": "codex-012345abcdef", "ZMX_SESSION": "pane"],
            records: [presence], isReachable: AttentionReportIdentity.hasCurrentProcessIdentity) == nil)
    }

    @Test("A native session cannot borrow a different thread's registration in the same pane")
    func rejectsDifferentNativeThread() {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let presence = TeamPresenceRecord(teamID: "/repo", worktree: "/repo", runtime: .codex,
            paneSessionName: "pane", pid: pid,
            processStartTimeMicroseconds: ProcessIdentityReader.startTimeMicroseconds(ofPID: pid),
            registeredAt: Date(), runtimeSessionID: "parent-thread", agentID: "codex-012345abcdef")
        #expect(AttentionReportIdentity.currentAgentID(worktreePath: "/repo",
            environment: ["GRAFTTY_AGENT_ID": "codex-012345abcdef", "ZMX_SESSION": "pane", "CODEX_SESSION_ID": "parent-thread", "CODEX_THREAD_ID": "child-thread"],
            records: [presence], isReachable: AttentionReportIdentity.hasCurrentProcessIdentity) == nil)
    }

    @Test("Claude presence remains owned when Codex native variables are inherited")
    func claudeIgnoresInheritedCodexSession() {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let presence = TeamPresenceRecord(teamID: "/repo", worktree: "/repo", runtime: .claude,
            paneSessionName: "pane", pid: pid,
            processStartTimeMicroseconds: ProcessIdentityReader.startTimeMicroseconds(ofPID: pid),
            registeredAt: Date(), runtimeSessionID: "claude-child", agentID: "claude-012345abcdef")
        #expect(AttentionReportIdentity.currentAgentID(worktreePath: "/repo",
            environment: ["GRAFTTY_AGENT_ID": "codex-111111111111", "ZMX_SESSION": "pane",
                "CODEX_SESSION_ID": "codex-parent", "CODEX_THREAD_ID": "codex-parent", "CLAUDE_SESSION_ID": "claude-child"],
            records: [presence], isReachable: AttentionReportIdentity.hasCurrentProcessIdentity) == "claude-012345abcdef")
    }

    @Test("Rejecting a Codex parent does not select an unrelated Claude in the same pane")
    func rejectionDoesNotChangeProviders() {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let start = ProcessIdentityReader.startTimeMicroseconds(ofPID: pid)
        let records = [TeamHookRuntime.codex, .claude].map { runtime in
            TeamPresenceRecord(teamID: "/repo", worktree: "/repo", runtime: runtime,
                paneSessionName: "pane", pid: pid, processStartTimeMicroseconds: start,
                registeredAt: Date(), runtimeSessionID: "parent", agentID: "\(runtime.rawValue)-012345abcdef")
        }
        #expect(AttentionReportIdentity.currentAgentID(worktreePath: "/repo",
            environment: ["GRAFTTY_AGENT_ID": "codex-012345abcdef", "ZMX_SESSION": "pane",
                "CODEX_SESSION_ID": "parent", "CODEX_THREAD_ID": "child"],
            records: records, isReachable: AttentionReportIdentity.hasCurrentProcessIdentity) == nil)
    }

}
