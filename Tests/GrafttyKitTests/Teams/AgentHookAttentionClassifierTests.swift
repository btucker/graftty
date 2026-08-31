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

        #expect(AgentHookAttentionClassifier.reason(
            runtime: .claude,
            event: .stop,
            stdinJSON: payload
        ) == nil)
    }

    @Test("""
    @spec AGENT-3.6: When a provider hook explicitly reports a surfaced permission request, user question, or plan-review prompt, the application shall create the corresponding needs-input attention for that agent.
    """, arguments: [
        (TeamHookRuntime.claude, TeamHookEvent.permissionRequest, ["tool_name": "Bash"], AgentHookAttentionReason.permission),
        (.claude, .permissionRequest, ["tool_name": "AskUserQuestion"], .question),
        (.claude, .permissionRequest, ["tool_name": "ExitPlanMode"], .planReview),
        (.claude, .preToolUse, ["tool_name": "AskUserQuestion"], .question),
        (.codex, .preToolUse, ["tool_name": "request_user_input"], .question),
        (.claude, .preToolUse, ["tool_name": "ExitPlanMode"], .planReview),
        (.codex, .preToolUse, ["tool_name": "exit_plan_mode"], .planReview),
    ])
    func explicitBlockingSignalCreatesAttention(
        runtime: TeamHookRuntime,
        event: TeamHookEvent,
        payload: [String: String],
        expected: AgentHookAttentionReason
    ) {
        #expect(AgentHookAttentionClassifier.reason(
            runtime: runtime,
            event: event,
            stdinJSON: payload
        ) == expected)
    }

    @Test("""
    @spec AGENT-3.8: When Codex emits PermissionRequest before its approval reviewer decides whether user input is required, the application shall not create needs-input attention.
    """)
    func codexPreReviewPermissionRequestStaysSilent() {
        #expect(AgentHookAttentionClassifier.reason(
            runtime: .codex,
            event: .permissionRequest,
            stdinJSON: ["tool_name": "Bash"]
        ) == nil)
    }

    @Test("Ordinary tool starts and lifecycle events are not attention signals", arguments: [
        (TeamHookEvent.preToolUse, ["tool_name": "Bash"]),
        (.postToolUse, ["tool_name": "Bash"]),
        (.sessionStart, [:]),
        (.stop, [:]),
    ])
    func nonBlockingSignalsStaySilent(event: TeamHookEvent, payload: [String: String]) {
        #expect(AgentHookAttentionClassifier.reason(
            runtime: .claude,
            event: event,
            stdinJSON: payload
        ) == nil)
    }

    @Test("Stop does not clear attention, while authoritative provider progress does", arguments: [
        (TeamHookEvent.stop, AgentHookAttentionAction.none),
        (.sessionStart, .clear),
        (.userPromptSubmit, .clear),
        (.postToolUse, .clear),
        (.postToolUseFailure, .clear),
    ])
    func attentionTransitions(event: TeamHookEvent, expected: AgentHookAttentionAction) {
        #expect(AgentHookAttentionTransition.action(event: event, reason: nil) == expected)
    }

    @Test("An explicit reason records attention regardless of hook event")
    func explicitReasonWinsTransition() {
        #expect(AgentHookAttentionTransition.action(
            event: .permissionRequest,
            reason: .question
        ) == .record(.question))
    }

    @Test("Stable provider identity prefers the native session and falls back to the wrapper agent")
    func stableProviderIdentity() {
        #expect(AgentHookAttentionIdentity.key(
            runtime: .codex,
            sessionID: " session-1 ",
            callerAgentID: "codex-agent"
        ) == "codex:session:session-1")
        #expect(AgentHookAttentionIdentity.key(
            runtime: .claude,
            sessionID: nil,
            callerAgentID: " claude-agent "
        ) == "claude:agent:claude-agent")
        #expect(AgentHookAttentionIdentity.key(
            runtime: .claude,
            sessionID: " ",
            callerAgentID: nil
        ) == nil)
    }
}
