import SwiftUI

/// Settings pane that exposes the `agentTeamsEnabled` toggle.
///
/// Implements TEAM-1.1, TEAM-1.2, TEAM-1.3 from SPECS.md.
struct AgentTeamsSettingsPane: View {
    @AppStorage("agentTeamsEnabled") private var agentTeamsEnabled: Bool = false
    @AppStorage("channelsEnabled") private var channelsEnabled: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable agent teams", isOn: Binding(
                    get: { agentTeamsEnabled },
                    set: { newValue in
                        agentTeamsEnabled = newValue
                        Self.applyTeamModeToggleSideEffects(
                            newValue: newValue,
                            defaults: .standard
                        )
                    }
                ))
            } footer: {
                Text("Turning this on auto-enables Channels and locks the Default Command field. Each Claude pane Graftty launches in a multi-worktree repo will receive team-aware instructions on connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if agentTeamsEnabled {
                Section("Managed default command") {
                    Text("claude --dangerously-load-development-channels server:graftty-channel")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 240)
    }

    /// Applies the team-mode → channels-mode dependency (TEAM-1.2).
    /// Static so tests can drive it without a SwiftUI environment.
    static func applyTeamModeToggleSideEffects(
        newValue: Bool,
        defaults: UserDefaults
    ) {
        if newValue && !defaults.bool(forKey: "channelsEnabled") {
            defaults.set(true, forKey: "channelsEnabled")
        }
    }

    /// Applies the channels-mode → team-mode dependency (TEAM-1.2):
    /// turning off channels also turns off team mode, since team mode requires channels.
    static func applyChannelsToggleSideEffects(
        newValue: Bool,
        defaults: UserDefaults
    ) {
        if !newValue && defaults.bool(forKey: "agentTeamsEnabled") {
            defaults.set(false, forKey: "agentTeamsEnabled")
        }
    }
}
