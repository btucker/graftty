import Testing
@testable import GrafttyKit

@Suite("Agent hook attention classification")
struct AgentHookAttentionClassifierTests {
    @Test("""
    @spec AGENT-3.5: When a top-level provider hook reports a bare turn Stop, the application shall not create needs-input attention or post a waiting-for-you notification.
    """)
    func bareStopIsNotAttention() {
        let payload: [String: Any] = [
            "session_id": "session-1",
            "hook_event_name": "Stop",
            "last_assistant_message": "Finished the requested work.",
        ]

        #expect(AgentHookAttentionClassifier.reason(event: .stop, stdinJSON: payload) == nil)
    }

    @Test("""
    @spec AGENT-3.6: When a provider hook explicitly reports a permission request, user question, or plan-review prompt, the application shall create the corresponding needs-input attention for that agent.
    """, arguments: [
        (TeamHookEvent.permissionRequest, [:], AgentHookAttentionReason.permission),
        (.preToolUse, ["tool_name": "AskUserQuestion"], .question),
        (.preToolUse, ["tool_name": "request_user_input"], .question),
        (.preToolUse, ["tool_name": "ExitPlanMode"], .planReview),
        (.preToolUse, ["tool_name": "exit_plan_mode"], .planReview),
    ])
    func explicitBlockingSignalCreatesAttention(
        event: TeamHookEvent,
        payload: [String: String],
        expected: AgentHookAttentionReason
    ) {
        #expect(AgentHookAttentionClassifier.reason(event: event, stdinJSON: payload) == expected)
    }

    @Test("Ordinary tool starts and lifecycle events are not attention signals", arguments: [
        (TeamHookEvent.preToolUse, ["tool_name": "Bash"]),
        (.postToolUse, ["tool_name": "Bash"]),
        (.sessionStart, [:]),
        (.stop, [:]),
    ])
    func nonBlockingSignalsStaySilent(event: TeamHookEvent, payload: [String: String]) {
        #expect(AgentHookAttentionClassifier.reason(event: event, stdinJSON: payload) == nil)
    }
}
