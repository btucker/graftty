import Foundation
import Testing
@testable import GrafttyKit

@Suite("""
@spec TEAM-9.1: When a Stop-event hook command (`graftty team hook \
<runtime> stop`) is invoked and the JSON the runtime wrote to the \
hook's stdin contains an `agent_id` string — Claude Code's marker that \
this Stop fired inside a Task subagent context rather than for a \
top-level agent turn — the CLI shall short-circuit before doing any \
per-Stop work: no `teamHook` socket message is sent. Without this \
filter, every Task subagent end can start redundant lifecycle work \
while the top-level agent is still working.
""")
struct AgentStopHookFilterTests {
    @Test func subagentStopIsDetectedWhenAgentIdIsPresent() {
        let payload: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": "abc",
            "agent_id": "subagent-uuid",
            "agent_type": "Explore",
        ]
        #expect(AgentStopHookFilter.isSubagentStop(stdinJSON: payload))
    }

    @Test func mainAgentStopIsNotDetectedAsSubagentWhenAgentIdIsAbsent() {
        let payload: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": "abc",
        ]
        #expect(!AgentStopHookFilter.isSubagentStop(stdinJSON: payload))
    }

    @Test func nonStringAgentIdDoesNotCountAsSubagent() {
        let payload: [String: Any] = [
            "agent_id": NSNull(),
            "session_id": "abc",
        ]
        #expect(!AgentStopHookFilter.isSubagentStop(stdinJSON: payload))
    }
}

@Suite("Claude Stop payloads report background subagents still in flight")
struct ClaudeRunningSubagentDetectionTests {
    @Test func runningSubagentIsDetected() {
        let payload: [String: Any] = ["background_tasks": [
            ["id": "t1", "type": "shell", "status": "running", "command": "npm run dev"],
            ["id": "t2", "type": "subagent", "status": "running", "agent_type": "Explore"],
        ]]
        #expect(AgentStopHookFilter.hasRunningSubagent(stdinJSON: payload))
    }

    @Test func otherBackgroundWorkIsNotASubagent() {
        let payloads: [[String: Any]] = [
            [:],
            ["background_tasks": []],
            ["background_tasks": NSNull()],
            ["background_tasks": "invalid"],
            ["background_tasks": [["type": "shell", "status": "running"], ["type": "monitor", "status": "running"]]],
            ["background_tasks": [], "session_crons": [["id": "c1", "recurring": true]]],
        ]
        for payload in payloads {
            #expect(!AgentStopHookFilter.hasRunningSubagent(stdinJSON: payload))
        }
    }
}
