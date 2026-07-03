import Testing
@testable import Graftty

@Suite("FlowStateSettingsPane")
struct FlowStateSettingsPaneTests {
    @Test("@spec FLOW-6.1: The application shall register non-empty Flow State defaults for enablement, runtime, and editable system prompt.")
    func defaultsAreRegisteredAndPromptIsNonEmpty() {
        #expect(!FlowStateDefaults.systemPrompt.isEmpty)
        #expect(FlowStateDefaults.systemPrompt.contains("Flow State"))
        #expect(FlowStateDefaults.registrations[SettingsKeys.flowStateSystemPrompt] as? String == FlowStateDefaults.systemPrompt)
        #expect(FlowStateDefaults.registrations[SettingsKeys.flowStateRuntime] as? String == "codex")
        #expect(FlowStateDefaults.registrations[SettingsKeys.flowStateEnabled] as? Bool == false)
        #expect(FlowStateDefaults.registrations[SettingsKeys.flowStatePermissionMode] as? String == "conservative")
        #expect(FlowStateDefaults.registrations[SettingsKeys.flowStateRefreshIntervalMinutes] as? Int == 10)
        #expect(FlowStateDefaults.registrations[SettingsKeys.flowStateStatusRequestCooldownMinutes] as? Int == 20)
    }

    @Test("@spec FLOW-6.2: The Flow State system prompt shall instruct the agent to preserve human flow and use `graftty flow` rather than acting as a repo-scoped team member.")
    func promptContainsCorePolicy() {
        let prompt = FlowStateDefaults.systemPrompt
        #expect(prompt.contains("preserve the human"))
        #expect(prompt.contains("context-switching cost"))
        #expect(prompt.contains("graftty flow context"))
        #expect(prompt.contains("graftty flow request-status"))
        #expect(prompt.contains("graftty flow publish --stdin"))
        #expect(prompt.contains("top-level Flow State coordinator"))
        #expect(prompt.contains("not a repo-scoped team member"))
        #expect(prompt.contains("Do not use graftty team send"))
        #expect(prompt.contains("Do not use graftty team broadcast"))
    }

    @Test("Flow State settings pane accepts lifecycle closure injection")
    func paneAcceptsLifecycleClosures() {
        _ = FlowStateSettingsPane(
            onStart: {},
            onStop: {},
            onRestart: {}
        )
    }
}
