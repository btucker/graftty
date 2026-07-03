import SwiftUI

/// Settings pane for the persistent Flow State coordinator.
struct FlowStateSettingsPane: View {
    @EnvironmentObject private var flowStateAgentController: FlowStateAgentController

    @AppStorage(SettingsKeys.flowStateEnabled) private var flowStateEnabled: Bool = false
    @AppStorage(SettingsKeys.flowStateRuntime) private var runtime: String = "codex"
    @AppStorage(SettingsKeys.flowStatePermissionMode) private var permissionMode: String = "conservative"
    @AppStorage(SettingsKeys.flowStateRefreshIntervalMinutes) private var refreshIntervalMinutes: Int = 10
    @AppStorage(SettingsKeys.flowStateStatusRequestCooldownMinutes) private var statusRequestCooldownMinutes: Int = 20
    @AppStorage(SettingsKeys.flowStateSystemPrompt) private var systemPrompt: String = FlowStateDefaults.systemPrompt

    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    var onRestart: () -> Void = {}
    var onConfirmRestart: () -> Void = {}

    init(
        onStart: @escaping () -> Void = {},
        onStop: @escaping () -> Void = {},
        onRestart: @escaping () -> Void = {},
        onConfirmRestart: @escaping () -> Void = {}
    ) {
        self.onStart = onStart
        self.onStop = onStop
        self.onRestart = onRestart
        self.onConfirmRestart = onConfirmRestart
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Flow State", isOn: $flowStateEnabled)
            }

            Section {
                LabeledContent("Status", value: lifecycleStatusText)

                if let reason = flowStateAgentController.pendingRestartReason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Restart Flow State Agent", action: onConfirmRestart)
                        Button("Cancel Restart") {
                            flowStateAgentController.cancelPendingRestart()
                        }
                    }
                }

                HStack {
                    Button("Start", action: onStart)
                    Button("Stop", action: onStop)
                    Button("Restart", action: onRestart)
                }
            } header: {
                Text("Lifecycle")
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
                }
            } header: {
                Text("System prompt")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 560)
        .onAppear(perform: reconcileLifecycleSettings)
        .onChange(of: flowStateEnabled) { _, _ in reconcileLifecycleSettings() }
        .onChange(of: runtime) { _, _ in reconcileLifecycleSettings() }
        .onChange(of: permissionMode) { _, _ in reconcileLifecycleSettings() }
        .onChange(of: systemPrompt) { _, _ in reconcileLifecycleSettings() }
    }

    private var lifecycleStatusText: String {
        let status = flowStateAgentController.status
        if let message = status.message, !message.isEmpty {
            return message
        }
        if !status.enabled { return "Flow State is off" }
        return status.running ? "Running" : "Idle"
    }

    private func reconcileLifecycleSettings() {
        flowStateAgentController.settingsDidChange(
            enabled: flowStateEnabled,
            runtime: FlowStateRuntime(settingsValue: runtime),
            systemPrompt: systemPrompt,
            permissionMode: permissionMode
        )
    }
}

#Preview {
    FlowStateSettingsPane()
        .environmentObject(FlowStateAgentController(
            launcher: FlowStateNoopAgentLauncher(),
            socketPath: "/tmp/graftty.sock"
        ))
}
