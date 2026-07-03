import SwiftUI

/// Settings pane for the persistent Flow State coordinator.
struct FlowStateSettingsPane: View {
    @AppStorage(SettingsKeys.flowStateEnabled) private var flowStateEnabled: Bool = false
    @AppStorage(SettingsKeys.flowStateRuntime) private var runtime: String = "codex"
    @AppStorage(SettingsKeys.flowStatePermissionMode) private var permissionMode: String = "conservative"
    @AppStorage(SettingsKeys.flowStateRefreshIntervalMinutes) private var refreshIntervalMinutes: Int = 10
    @AppStorage(SettingsKeys.flowStateStatusRequestCooldownMinutes) private var statusRequestCooldownMinutes: Int = 20
    @AppStorage(SettingsKeys.flowStateSystemPrompt) private var systemPrompt: String = FlowStateDefaults.systemPrompt

    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    var onRestart: () -> Void = {}

    init(
        onStart: @escaping () -> Void = {},
        onStop: @escaping () -> Void = {},
        onRestart: @escaping () -> Void = {}
    ) {
        self.onStart = onStart
        self.onStop = onStop
        self.onRestart = onRestart
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Flow State", isOn: $flowStateEnabled)
            }

            Section {
                Picker("Runtime", selection: $runtime) {
                    Text("Codex").tag("codex")
                    Text("Claude").tag("claude")
                }

                Picker("Permission mode", selection: $permissionMode) {
                    Text("Conservative").tag("conservative")
                    Text("Manual Only").tag("manualOnly")
                }
            } header: {
                Text("Runtime")
            }

            Section {
                Stepper(value: $refreshIntervalMinutes, in: 1...240, step: 1) {
                    LabeledContent("Refresh interval", value: "\(refreshIntervalMinutes) min")
                }

                Stepper(value: $statusRequestCooldownMinutes, in: 1...240, step: 1) {
                    LabeledContent("Status cooldown", value: "\(statusRequestCooldownMinutes) min")
                }
            } header: {
                Text("Cadence")
            }

            Section {
                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 180)
                    .font(.system(.body, design: .monospaced))

                HStack {
                    Button("Reset Prompt") {
                        systemPrompt = FlowStateDefaults.systemPrompt
                    }

                    Spacer()

                    Button("Start", action: onStart)
                    Button("Stop", action: onStop)
                    Button("Restart", action: onRestart)
                }
            } header: {
                Text("System prompt")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 560)
    }
}

#Preview {
    FlowStateSettingsPane()
}
